internal import Darwin
public import CmuxTerminalRenderTransport
public import Foundation

/// Supervises the single faceless process that owns all Ghostty render mirrors.
///
/// The host never waits for a renderer response. Commands enter
/// ``commandSink`` from one ordered lane, writes happen off the main actor, and
/// worker generations fence late events and IOSurfaces after a crash.
public actor GhosttyRenderWorkerClient {
    /// App-relative location of the dedicated AppKit-free worker executable.
    public nonisolated static let bundledWorkerRelativePath = "bin/cmux-ghostty-render-worker"

    /// Ordered, nonblocking ingress used by AppKit and Ghostty I/O callbacks.
    public nonisolated let commandSink = GhosttyRenderCommandSink()

    private let executableURL: URL
    private let arguments: [String]
    private let extraEnvironment: [String: String]
    private let initializationTimeout: Duration
    private let automaticInitializationRetryLimit: Int
    private let frameReceiver: TerminalRenderFrameReceiver
    private let frameIngress: AsyncStream<TerminalRenderFrame>
    private let frameContinuation: AsyncStream<TerminalRenderFrame>.Continuation
    private let controlIngress: AsyncStream<GhosttyRenderChildControlIngress>
    private let controlContinuation: AsyncStream<GhosttyRenderChildControlIngress>.Continuation

    private var commandConsumer: Task<Void, Never>?
    private var frameConsumer: Task<Void, Never>?
    private var controlConsumer: Task<Void, Never>?
    private var initializationWatchdog: Task<Void, Never>?
    private var frameThread: Thread?
    private var child: GhosttyRenderChild?
    private var workerGeneration: UInt64 = 0
    private var initializedGeneration: UInt64?
    private var consecutiveInitializationTimeouts = 0
    private var hasLaunchedWorker = false
    private var isShuttingDown = false
    private var configuration: TerminalRenderConfigurationSnapshot?
    private var desiredSurfaces: [UUID: TerminalRenderSurfaceDescriptor] = [:]
    private var resynchronizingSurfaces: Set<UUID> = []
    private var pendingMutations: [UUID: [TerminalRenderWorkerCommand]] = [:]
    private var inFlightResizes: [UUID: GhosttyRenderInFlightResize] = [:]

    private var eventSubscribers: [Int: AsyncStream<GhosttyRenderWorkerClientEvent>.Continuation] = [:]
    private var frameSubscribers: [Int: AsyncStream<TerminalRenderFrame>.Continuation] = [:]
    private var nextSubscriberID = 0

    /// Creates a client that launches `executableURL` on demand.
    public init(
        executableURL: URL,
        arguments: [String] = [],
        environment extraEnvironment: [String: String] = [:],
        frameReceiver: TerminalRenderFrameReceiver? = nil,
        initializationTimeout: Duration = .seconds(5),
        automaticInitializationRetryLimit: Int = 1
    ) throws {
        self.executableURL = executableURL
        self.arguments = arguments
        self.extraEnvironment = extraEnvironment
        self.initializationTimeout = initializationTimeout
        self.automaticInitializationRetryLimit = max(0, automaticInitializationRetryLimit)
        self.frameReceiver = try frameReceiver ?? TerminalRenderFrameReceiver()
        let framePair = AsyncStream.makeStream(
            of: TerminalRenderFrame.self,
            bufferingPolicy: .bufferingNewest(8)
        )
        self.frameIngress = framePair.stream
        self.frameContinuation = framePair.continuation
        let controlPair = AsyncStream.makeStream(
            of: GhosttyRenderChildControlIngress.self,
            bufferingPolicy: .unbounded
        )
        self.controlIngress = controlPair.stream
        self.controlContinuation = controlPair.continuation
    }

    /// Creates a client for the dedicated worker bundled with the app.
    public static func bundledWorker(in bundle: Bundle = .main) throws -> GhosttyRenderWorkerClient {
        guard let resources = bundle.resourceURL else {
            throw GhosttyRenderWorkerLaunchError.missingResourceDirectory
        }
        let executable = resources.appendingPathComponent(bundledWorkerRelativePath)
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw GhosttyRenderWorkerLaunchError.missingBundledWorker(executable)
        }
        return try GhosttyRenderWorkerClient(executableURL: executable)
    }

    /// Starts the ordered consumers. Safe to call repeatedly.
    public func start() {
        guard commandConsumer == nil else { return }
        let commandStream = commandSink.stream
        commandConsumer = Task { [weak self] in
            for await command in commandStream {
                guard let self else { return }
                await self.accept(command)
            }
        }
        let frames = frameIngress
        frameConsumer = Task { [weak self] in
            for await frame in frames {
                guard let self else { return }
                await self.accept(frame)
            }
        }
        let controlMessages = controlIngress
        controlConsumer = Task { [weak self] in
            for await message in controlMessages {
                guard let self else { return }
                await self.accept(message)
            }
        }
        let frameContinuation = frameContinuation
        frameThread = frameReceiver.start { frame in
            frameContinuation.yield(frame)
        }
    }

    /// Installs or replaces the effective Ghostty configuration snapshot.
    public func updateConfiguration(_ snapshot: TerminalRenderConfigurationSnapshot) {
        start()
        commandSink.enqueue(.replaceConfiguration(snapshot))
    }

    /// Subscribes to process lifecycle and recovery requests.
    public func subscribeEvents() -> AsyncStream<GhosttyRenderWorkerClientEvent> {
        let id = allocateSubscriberID()
        return AsyncStream { continuation in
            eventSubscribers[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeEventSubscriber(id) }
            }
        }
    }

    /// Subscribes to generation-fenced rendered frames.
    public func subscribeFrames() -> AsyncStream<TerminalRenderFrame> {
        let id = allocateSubscriberID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(3)) { continuation in
            frameSubscribers[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeFrameSubscriber(id) }
            }
        }
    }

    /// Terminates the worker and all local streams.
    public func shutdown() {
        isShuttingDown = true
        initializationWatchdog?.cancel()
        initializationWatchdog = nil
        if let child {
            try? send(.shutdown, through: child.channel)
            child.process.terminate()
        }
        child = nil
        commandSink.finish()
        commandConsumer?.cancel()
        commandConsumer = nil
        frameConsumer?.cancel()
        frameConsumer = nil
        controlConsumer?.cancel()
        controlConsumer = nil
        frameContinuation.finish()
        controlContinuation.finish()
        frameReceiver.stop()
        pendingMutations.removeAll()
        inFlightResizes.removeAll()
        for continuation in eventSubscribers.values { continuation.finish() }
        for continuation in frameSubscribers.values { continuation.finish() }
        eventSubscribers.removeAll()
        frameSubscribers.removeAll()
    }

    private func accept(_ command: TerminalRenderWorkerCommand) {
        switch command {
        case .initialize:
            broadcast(.failure("host attempted to enqueue worker initialization"))

        case let .replaceConfiguration(snapshot):
            if let configuration, snapshot.revision <= configuration.revision {
                return
            }
            let hadConfiguration = configuration != nil
            configuration = snapshot
            do {
                let launched = try ensureRunning()
                if hadConfiguration, !launched, let channel = child?.channel {
                    try send(command, through: channel)
                }
            } catch {
                loseWorker(reason: "configuration send failed: \(error)")
            }

        case let .createSurface(descriptor):
            desiredSurfaces[descriptor.id] = descriptor
            resynchronizingSurfaces.remove(descriptor.id)
            pendingMutations[descriptor.id] = nil
            inFlightResizes[descriptor.id] = nil
            guard configuration != nil else { return }
            do {
                let launched = try ensureRunning()
                if !launched, let channel = child?.channel {
                    try send(command, through: channel)
                }
            } catch {
                loseWorker(reason: "surface create send failed: \(error)")
            }

        case let .mutateSurface(id, generation, _):
            guard desiredSurfaces[id]?.generation == generation else { return }
            guard configuration != nil else {
                enqueuePendingMutation(command)
                return
            }
            do {
                _ = try ensureRunning()
                guard !resynchronizingSurfaces.contains(id),
                      inFlightResizes[id] == nil,
                      let channel = child?.channel else {
                    enqueuePendingMutation(command)
                    return
                }
                try sendScheduledMutation(command, through: channel)
            } catch {
                enqueuePendingMutation(command)
                loseWorker(reason: "surface mutation send failed: \(error)")
            }

        case let .resynchronizeSurface(descriptor, nextSequence, _):
            guard desiredSurfaces[descriptor.id]?.generation == descriptor.generation else { return }
            do {
                _ = try ensureRunning()
                guard let channel = child?.channel else { return }
                try send(command, through: channel)
                resynchronizingSurfaces.remove(descriptor.id)
                inFlightResizes[descriptor.id] = nil
                let queued = pendingMutations.removeValue(forKey: descriptor.id) ?? []
                let trimmed = queued.compactMap { trim($0, before: nextSequence) }
                if !trimmed.isEmpty {
                    pendingMutations[descriptor.id] = trimmed
                }
                try drainPendingMutations(for: descriptor.id, through: channel)
            } catch {
                loseWorker(reason: "surface resynchronization failed: \(error)")
            }

        case let .destroySurface(id, generation):
            guard desiredSurfaces[id]?.generation == generation else { return }
            desiredSurfaces[id] = nil
            resynchronizingSurfaces.remove(id)
            pendingMutations[id] = nil
            inFlightResizes[id] = nil
            if let channel = child?.channel {
                do { try send(command, through: channel) }
                catch { loseWorker(reason: "surface destroy send failed: \(error)") }
            }

        case .shutdown:
            shutdown()
        }
    }

    @discardableResult
    private func ensureRunning() throws -> Bool {
        guard !isShuttingDown else { return false }
        if let child, child.process.isRunning { return false }
        guard let configuration else { return false }

        workerGeneration &+= 1
        let generation = workerGeneration
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        if !extraEnvironment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment
                .merging(extraEnvironment) { _, new in new }
        }
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        let channel = TerminalRenderMessageChannel(
            readDescriptor: stdout.fileHandleForReading.fileDescriptor,
            writeDescriptor: stdin.fileHandleForWriting.fileDescriptor,
            nonblockingWrites: true
        )
        try process.run()
        child = GhosttyRenderChild(
            generation: generation,
            process: process,
            channel: channel,
            stdin: stdin,
            stdout: stdout
        )
        initializedGeneration = nil

        let readChannel = channel
        let controlContinuation = controlContinuation
        let reader = Thread {
            withExtendedLifetime(stdout) {
                while let payload = readChannel.receive() {
                    guard let event = try? TerminalRenderControlCodec.decodeEvent(payload) else {
                        continue
                    }
                    controlContinuation.yield(.event(event, generation: generation))
                }
                controlContinuation.yield(.ended(generation: generation))
            }
        }
        reader.name = "cmux-ghostty-render-control-reader"
        reader.stackSize = 1 << 20
        reader.start()

        try send(
            .initialize(
                protocolVersion: TerminalRenderProtocol.currentVersion,
                workerGeneration: generation,
                frameEndpoint: frameReceiver.endpoint,
                configuration: configuration
            ),
            through: channel
        )
        armInitializationWatchdog(generation: generation)

        if hasLaunchedWorker {
            resynchronizingSurfaces = Set(desiredSurfaces.keys)
            for descriptor in desiredSurfaces.values {
                broadcast(.resynchronizationRequired(
                    surfaceID: descriptor.id,
                    surfaceGeneration: descriptor.generation
                ))
            }
        } else {
            for descriptor in desiredSurfaces.values {
                try send(.createSurface(descriptor), through: channel)
            }
            for id in Array(pendingMutations.keys) {
                try drainPendingMutations(for: id, through: channel)
            }
        }
        hasLaunchedWorker = true
        return true
    }

    private func accept(_ message: GhosttyRenderChildControlIngress) {
        switch message {
        case let .event(event, generation):
            accept(event, generation: generation)
        case let .ended(generation):
            workerEnded(generation: generation)
        case let .initializationTimedOut(generation):
            initializationTimedOut(generation: generation)
        }
    }

    private func accept(_ event: TerminalRenderWorkerEvent, generation: UInt64) {
        guard child?.generation == generation else { return }
        switch event {
        case let .initialized(version, announcedGeneration, processIdentifier):
            guard version == TerminalRenderProtocol.currentVersion,
                  announcedGeneration == generation else {
                loseWorker(reason: "worker protocol generation mismatch")
                return
            }
            guard initializedGeneration != generation else { return }
            initializedGeneration = generation
            consecutiveInitializationTimeouts = 0
            initializationWatchdog?.cancel()
            initializationWatchdog = nil
            broadcast(.initialized(
                workerGeneration: generation,
                processIdentifier: processIdentifier
            ))
        case let .surfaceCreated(id, surfaceGeneration):
            guard initializedGeneration == generation else {
                loseWorker(reason: "worker created a surface before initialization")
                return
            }
            guard desiredSurfaces[id]?.generation == surfaceGeneration else { return }
            broadcast(.surfaceCreated(
                surfaceID: id,
                surfaceGeneration: surfaceGeneration
            ))
        case .surfaceDestroyed:
            break
        case let .outputApplied(id, surfaceGeneration, nextSequence):
            guard initializedGeneration == generation else {
                loseWorker(reason: "worker applied output before initialization")
                return
            }
            guard desiredSurfaces[id]?.generation == surfaceGeneration else { return }
            broadcast(.outputApplied(
                surfaceID: id,
                surfaceGeneration: surfaceGeneration,
                nextSequence: nextSequence
            ))
        case let .resizeApplied(id, surfaceGeneration, width, height):
            guard initializedGeneration == generation else {
                loseWorker(reason: "worker applied a resize before initialization")
                return
            }
            guard desiredSurfaces[id]?.generation == surfaceGeneration,
                  let inFlight = inFlightResizes[id],
                  inFlight.generation == surfaceGeneration,
                  inFlight.width == width,
                  inFlight.height == height else {
                return
            }
            inFlightResizes[id] = nil
            guard let channel = child?.channel else { return }
            do {
                try drainPendingMutations(for: id, through: channel)
            } catch {
                loseWorker(reason: "queued surface mutation send failed: \(error)")
            }
        case let .failure(message):
            broadcast(.failure(message))
        }
    }

    private func accept(_ frame: TerminalRenderFrame) {
        guard frame.metadata.workerGeneration == workerGeneration,
              desiredSurfaces[frame.metadata.surfaceID]?.generation
                == frame.metadata.surfaceGeneration,
              !resynchronizingSurfaces.contains(frame.metadata.surfaceID) else {
            return
        }
        for continuation in frameSubscribers.values {
            continuation.yield(frame)
        }
    }

    private func workerEnded(generation: UInt64) {
        guard let endedChild = child, endedChild.generation == generation else { return }
        initializationWatchdog?.cancel()
        initializationWatchdog = nil
        initializedGeneration = nil
        if endedChild.process.isRunning {
            endedChild.process.terminate()
        }
        child = nil
        inFlightResizes.removeAll()
        resynchronizingSurfaces.formUnion(desiredSurfaces.keys)
        broadcast(.workerExited(workerGeneration: generation))
    }

    private func loseWorker(reason: String) {
        initializationWatchdog?.cancel()
        initializationWatchdog = nil
        initializedGeneration = nil
        guard let lostChild = child else {
            broadcast(.failure(reason))
            return
        }
        let generation = lostChild.generation
        if lostChild.process.isRunning {
            lostChild.process.terminate()
        }
        child = nil
        inFlightResizes.removeAll()
        resynchronizingSurfaces.formUnion(desiredSurfaces.keys)
        broadcast(.failure(reason))
        broadcast(.workerExited(workerGeneration: generation))
    }

    private func armInitializationWatchdog(generation: UInt64) {
        initializationWatchdog?.cancel()
        let timeout = initializationTimeout
        let controlContinuation = controlContinuation
        initializationWatchdog = Task {
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            controlContinuation.yield(.initializationTimedOut(generation: generation))
        }
    }

    private func initializationTimedOut(generation: UInt64) {
        guard !isShuttingDown,
              child?.generation == generation,
              initializedGeneration != generation else {
            return
        }

        consecutiveInitializationTimeouts += 1
        loseWorker(reason: "worker initialization timed out")

        guard consecutiveInitializationTimeouts <= automaticInitializationRetryLimit else {
            return
        }
        do {
            _ = try ensureRunning()
        } catch {
            broadcast(.failure("worker restart failed: \(error)"))
        }
    }

    private func send(
        _ command: TerminalRenderWorkerCommand,
        through channel: TerminalRenderMessageChannel
    ) throws {
        try channel.send(TerminalRenderControlCodec.encode(command))
    }

    private func sendScheduledMutation(
        _ command: TerminalRenderWorkerCommand,
        through channel: TerminalRenderMessageChannel
    ) throws {
        try send(command, through: channel)
        guard let resize = resizeIdentity(for: command) else { return }
        inFlightResizes[resize.id] = resize.inFlight
    }

    private func enqueuePendingMutation(_ command: TerminalRenderWorkerCommand) {
        guard case let .mutateSurface(id, generation, mutation) = command else { return }
        var queued = pendingMutations[id] ?? []
        if case .resize = mutation,
           let last = queued.last,
           case let .mutateSurface(lastID, lastGeneration, lastMutation) = last,
           lastID == id,
           lastGeneration == generation,
           case .resize = lastMutation {
            queued[queued.index(before: queued.endIndex)] = command
        } else {
            queued.append(command)
        }
        pendingMutations[id] = queued
    }

    private func drainPendingMutations(
        for id: UUID,
        through channel: TerminalRenderMessageChannel
    ) throws {
        guard inFlightResizes[id] == nil,
              let queued = pendingMutations.removeValue(forKey: id) else {
            return
        }

        for index in queued.indices {
            do {
                try sendScheduledMutation(queued[index], through: channel)
            } catch {
                pendingMutations[id] = Array(queued[index...])
                throw error
            }
            guard inFlightResizes[id] == nil else {
                let nextIndex = queued.index(after: index)
                if nextIndex < queued.endIndex {
                    pendingMutations[id] = Array(queued[nextIndex...])
                }
                return
            }
        }
    }

    private func resizeIdentity(
        for command: TerminalRenderWorkerCommand
    ) -> (id: UUID, inFlight: GhosttyRenderInFlightResize)? {
        guard case let .mutateSurface(id, generation, mutation) = command,
              case let .resize(width, height) = mutation else {
            return nil
        }
        return (
            id,
            GhosttyRenderInFlightResize(
                generation: generation,
                width: width,
                height: height
            )
        )
    }

    private func trim(
        _ command: TerminalRenderWorkerCommand,
        before nextSequence: UInt64
    ) -> TerminalRenderWorkerCommand? {
        guard case let .mutateSurface(id, generation, mutation) = command,
              case let .processOutput(sequence, bytes) = mutation else {
            return command
        }
        let end = sequence &+ UInt64(bytes.count)
        guard end > nextSequence else { return nil }
        guard sequence < nextSequence else { return command }
        let dropCount = Int(nextSequence - sequence)
        return .mutateSurface(
            id: id,
            generation: generation,
            mutation: .processOutput(
                sequence: nextSequence,
                bytes: Data(bytes.dropFirst(dropCount))
            )
        )
    }

    private func allocateSubscriberID() -> Int {
        defer { nextSubscriberID += 1 }
        return nextSubscriberID
    }

    private func removeEventSubscriber(_ id: Int) {
        eventSubscribers[id] = nil
    }

    private func removeFrameSubscriber(_ id: Int) {
        frameSubscribers[id] = nil
    }

    private func broadcast(_ event: GhosttyRenderWorkerClientEvent) {
        for continuation in eventSubscribers.values {
            continuation.yield(event)
        }
    }
}

/// Failures resolving the dedicated renderer executable from the app bundle.
public enum GhosttyRenderWorkerLaunchError: Error, Equatable, Sendable {
    case missingResourceDirectory
    case missingBundledWorker(URL)
}

private struct GhosttyRenderChild {
    let generation: UInt64
    let process: Process
    let channel: TerminalRenderMessageChannel
    let stdin: Pipe
    let stdout: Pipe
}

private struct GhosttyRenderInFlightResize {
    let generation: UInt64
    let width: UInt32
    let height: UInt32
}

private enum GhosttyRenderChildControlIngress: Sendable {
    case event(TerminalRenderWorkerEvent, generation: UInt64)
    case ended(generation: UInt64)
    case initializationTimedOut(generation: UInt64)
}
