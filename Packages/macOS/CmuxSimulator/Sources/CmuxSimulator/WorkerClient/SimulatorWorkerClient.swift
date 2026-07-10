import Foundation

/// Supervises the isolated Simulator framebuffer/input worker and exposes the
/// supported `simctl` control surface to a native pane.
///
/// Private Simulator frameworks are loaded only by the re-executed child. A
/// child crash closes this client's pipe, clears the remote layer, and spends
/// one automatic restart. A second failure trips a fuse until an explicit
/// activation or ``recover()`` call.
public actor SimulatorWorkerClient: SimulatorPaneClient {
    /// The argument that selects Simulator-worker mode before app startup.
    public static let workerModeArgument = "--cmux-simulator-worker"
    static let maximumSubscriberBufferedBytes = 32 * 1_024 * 1_024
    static let maximumSubscriberEventCount = 1_024

    /// A synchronously readable mirror of the current remote layer context.
    public nonisolated let contextCache = SimulatorRemoteContextCache()

    let executableURL: URL
    let arguments: [String]
    let environment: [String: String]
    let ackTimeout: Duration
    let replayTimeout: Duration
    let launcher: any SimulatorWorkerLaunching
    let sleeper: any SimulatorWorkerSleeping
    let simulatorControl: any SimulatorControlling

    var child: SimulatorWorkerConnection?
    var readerTask: Task<Void, Never>?
    var gracefulTerminationTask: Task<Void, Never>?
    var generation: UInt64 = 0
    var restartAttemptUsed = false
    var crashFuseTripped = false
    var isClosing = false
    var isPermanentlyStopped = false

    var nextPingSequence: UInt64 = 1
    var pendingPingSequence: UInt64?
    var probeNeededAfterAcknowledgement = false
    var ackWatchdog: Task<Void, Never>?

    var subscribers: [Int: SimulatorWorkerEventStream.Continuation] = [:]
    var nextSubscriberID = 0
    var currentContextID: UInt32?
    var currentCapabilities: Set<SimulatorCapability> = []
    var currentStatus: SimulatorSessionStatus?

    var lastAttachment: SimulatorWorkerInbound?
    var lastGeometry: SimulatorSurfaceGeometry?
    var lastDisplayOrientation: SimulatorOrientation?
    var cameraReplayConfigurations: [SimulatorCameraConfiguration] = []
    var cameraReplayRequestConfigurations: [UUID: SimulatorCameraConfiguration] = [:]
    var cameraCleanupBundleIdentifiers: Set<String> = []
    var lastCameraMirrorMode: SimulatorCameraMirrorMode?
    var cameraCleanupTask: Task<Void, Never>?
    var cameraCleanupRevision: UInt64 = 0
    var activePointer: SimulatorPointerEvent?
    var pointerStateRevision: UInt64?
    var heldKeyUsages: Set<UInt32> = []
    var keyStateRevisions: [UInt32: UInt64] = [:]
    var pendingTextInputUsages: [UUID: Set<UInt32>] = [:]
    var heldButtonUsages: Set<SimulatorHIDButtonUsage> = []
    var buttonStateRevisions: [SimulatorHIDButtonUsage: UInt64] = [:]
    var nextInputStateRevision: UInt64 = 1
    var unprovenInputRelease = SimulatorInputReleaseProof()
    var inputReleaseProofs: [UInt64: SimulatorInputReleaseProof] = [:]
    var unprovenConvenienceButtonUsages: Set<SimulatorHIDButtonUsage> = []
    var convenienceButtonProofs: [UInt64: Set<SimulatorHIDButtonUsage>] = [:]
    var replayAwaitingStreaming = false
    var replayRequestIDs: Set<UUID> = []
    var probeNeededAfterReplay = false
    var replayWatchdog: Task<Void, Never>?

    /// Creates a client that launches the supplied executable on demand.
    /// - Parameters:
    ///   - executableURL: Host binary re-executed as the worker.
    ///   - arguments: Worker-mode process arguments.
    ///   - environment: Additional child environment values.
    ///   - ackTimeout: Ordered ping deadline before the worker is considered hung.
    ///   - simulatorControl: Injected public Simulator control service.
    public init(
        executableURL: URL,
        arguments: [String] = [SimulatorWorkerClient.workerModeArgument],
        environment: [String: String] = [:],
        ackTimeout: Duration = .seconds(3),
        simulatorControl: any SimulatorControlling = SimulatorControlService()
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.ackTimeout = ackTimeout
        self.replayTimeout = .seconds(120)
        self.launcher = SimulatorProcessWorkerLauncher()
        self.sleeper = ContinuousSimulatorWorkerSleeper()
        self.simulatorControl = simulatorControl
    }

    init(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        ackTimeout: Duration,
        replayTimeout: Duration = .seconds(120),
        simulatorControl: any SimulatorControlling,
        launcher: any SimulatorWorkerLaunching,
        sleeper: any SimulatorWorkerSleeping = ContinuousSimulatorWorkerSleeper()
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.ackTimeout = ackTimeout
        self.replayTimeout = replayTimeout
        self.simulatorControl = simulatorControl
        self.launcher = launcher
        self.sleeper = sleeper
    }

    deinit {
        readerTask?.cancel()
        ackWatchdog?.cancel()
        replayWatchdog?.cancel()
        gracefulTerminationTask?.cancel()
        let deviceIdentifier = Self.attachedDeviceIdentifier(from: lastAttachment)
        let bundleIdentifiers = Array(cameraCleanupBundleIdentifiers.union(
            cameraReplayConfigurations.compactMap(\.targetBundleIdentifier)
        ).filter { !$0.isEmpty }).sorted()
        if !crashFuseTripped,
           let deviceIdentifier,
           !bundleIdentifiers.isEmpty {
            let pendingCleanup = cameraCleanupTask
            let simulatorControl = self.simulatorControl
            Task {
                await pendingCleanup?.value
                await Self.cleanCameraInjections(
                    deviceIdentifier: deviceIdentifier,
                    bundleIdentifiers: bundleIdentifiers,
                    simulatorControl: simulatorControl
                )
            }
        }
        if let child {
            Self.unlinkCameraSharedMemory(
                connection: child,
                deviceIdentifier: deviceIdentifier
            )
            child.terminate()
        }
    }

    /// Creates a client that re-executes the current app binary in worker mode.
    /// - Parameters:
    ///   - ackTimeout: Ordered ping deadline before treating the child as hung.
    ///   - simulatorControl: Injected public Simulator control service.
    public static func reexecingCurrentBinary(
        ackTimeout: Duration = .seconds(3),
        simulatorControl: any SimulatorControlling = SimulatorControlService()
    ) -> SimulatorWorkerClient {
        let executableURL = Bundle.main.executableURL
            ?? URL(fileURLWithPath: CommandLine.arguments[0])
        return SimulatorWorkerClient(
            executableURL: executableURL,
            ackTimeout: ackTimeout,
            simulatorControl: simulatorControl
        )
    }

    /// Returns installed Simulator devices through the injected control service.
    public func discoverDevices() async throws -> [SimulatorDevice] {
        try requireOpen()
        return try await simulatorControl.discoverDevices()
    }

    /// Boots, waits for, and attaches the isolated worker to a device.
    public func activateDevice(id: String, geometry: SimulatorSurfaceGeometry?) async throws {
        try requireOpen()
        await waitForCameraCleanup()
        try requireOpen()
        try await simulatorControl.boot(deviceID: id)
        try Task.checkCancellation()
        try await simulatorControl.waitUntilBooted(deviceID: id)
        try Task.checkCancellation()

        prepareExplicitRecovery()
        replaceWorkerForAttachmentIfNeeded()
        prepareForAttachment(deviceIdentifier: id)
        let attached: Bool = try await requestWorkerValue(
            sending: .attach(udid: id, geometry: geometry),
            timeout: .seconds(90)
        ) { message in
            guard case let .status(status) = message else { return nil }
            switch status {
            case .streaming:
                return true
            case .deviceUnavailable, .failed:
                return false
            case .idle, .connecting, .workerCrashed:
                return nil
            }
        }
        guard attached else {
            throw SimulatorControlError(
                code: "device_activation_failed",
                arguments: [],
                message: "The isolated worker could not attach to the selected Simulator."
            )
        }
    }

    /// Releases the worker, then shuts down a CoreSimulator device.
    public func shutdownDevice(id: String) async throws {
        try requireOpen()
        if child != nil {
            try? await sendRequired(.releaseInputs, probe: false)
            try? await sendRequired(.shutdown, probe: false)
        }
        discardWorker(intentional: true, clearReplayState: true, graceful: true)
        try await simulatorControl.shutdown(deviceID: id)
    }

    /// Subscribes to process-safe worker messages and lifecycle changes.
    public func subscribe() async -> SimulatorWorkerEventStream {
        if isPermanentlyStopped {
            let (stream, continuation) = SimulatorWorkerEventStream.makeStream(
                maximumBufferedBytes: 1,
                maximumBufferedEvents: 1,
                onTermination: {}
            )
            continuation.finish()
            return stream
        }
        let identifier = nextSubscriberID
        nextSubscriberID += 1
        let (stream, continuation) = SimulatorWorkerEventStream.makeStream(
            maximumBufferedBytes: Self.maximumSubscriberBufferedBytes,
            maximumBufferedEvents: Self.maximumSubscriberEventCount
        ) { [weak self] in
            Task { [weak self] in
                await self?.removeSubscriber(identifier)
            }
        }
        subscribers[identifier] = continuation
        if let currentContextID {
            yield(.message(.context(currentContextID)), to: continuation)
        }
        if !currentCapabilities.isEmpty {
            yield(.message(.capabilities(currentCapabilities)), to: continuation)
        }
        if let currentStatus {
            yield(.message(.status(currentStatus)), to: continuation)
        }
        return stream
    }

    /// Sends one typed command. Failures arrive through the event stream so
    /// high-frequency input producers never block on process recovery.
    public func send(_ message: SimulatorWorkerInbound) async {
        do {
            if case let .typeText(requestID, sequence) = message {
                let _: Bool = try await requestWorkerValue(
                    sending: message,
                    timeout: .seconds(sequence.completionTimeoutSeconds)
                ) { outbound in
                    guard case let .textInput(responseID, succeeded) = outbound,
                          responseID == requestID else { return nil }
                    return succeeded
                }
                return
            }
            try await sendRequired(message)
        } catch {
            broadcastFailure(error, code: "worker_send_failed")
        }
    }
    /// Clears a tripped crash fuse and relaunches the worker with its last
    /// attachment and geometry.
    public func recover() async throws {
        try requireOpen()
        await waitForCameraCleanup()
        try requireOpen()
        prepareExplicitRecovery()
        _ = try ensureRunning()
    }

    public func invalidateWorker() async {
        guard !isPermanentlyStopped else { return }
        let cleanup = cameraCleanupSnapshot()
        let cleanupAlreadyQueued = crashFuseTripped
        sendClosingMessages(shutdown: false)
        discardWorker(
            intentional: true,
            clearReplayState: true,
            graceful: cleanup.bundleIdentifiers.isEmpty
        )
        if !cleanupAlreadyQueued { enqueueCameraCleanup(cleanup) }
        await waitForCameraCleanup()
        broadcast(.workerStopped)
    }

    /// Releases input, requests clean worker shutdown, and closes every event
    /// stream without stopping the CoreSimulator device.
    public func stop() async {
        guard !isPermanentlyStopped, !isClosing else { return }
        isClosing = true
        let cleanup = cameraCleanupSnapshot()
        let cleanupAlreadyQueued = crashFuseTripped
        sendClosingMessages(shutdown: true)
        discardWorker(
            intentional: true,
            clearReplayState: true,
            graceful: cleanup.bundleIdentifiers.isEmpty
        )
        isPermanentlyStopped = true
        isClosing = true
        if !cleanupAlreadyQueued { enqueueCameraCleanup(cleanup) }
        await waitForCameraCleanup()
        for continuation in subscribers.values {
            continuation.finish()
        }
        subscribers.removeAll()
    }

    func sendRequired(
        _ message: SimulatorWorkerInbound,
        probe: Bool = true
    ) async throws {
        try requireOpen()
        if crashFuseTripped {
            throw SimulatorControlError(
                code: "worker_crash_fuse",
                arguments: arguments,
                message: "The Simulator worker failed twice. Recover the pane before retrying."
            )
        }

        let data = try JSONEncoder().encode(message)
        for attempt in 0..<2 {
            do {
                let connection = try ensureRunning()
                try connection.send(data)
                remember(message)
                if probe { try armResponsivenessProbe() }
                return
            } catch {
                discardWorker(intentional: true, clearReplayState: false)
                if attempt == 0, !restartAttemptUsed {
                    restartAttemptUsed = true
                    continue
                }
                tripCrashFuse(reason: error)
                throw SimulatorControlError(
                    code: "worker_unavailable",
                    arguments: arguments,
                    message: "The isolated Simulator worker could not accept a command: \(error)"
                )
            }
        }
    }

    func removeSubscriber(_ identifier: Int) {
        subscribers.removeValue(forKey: identifier)
    }

    func requireOpen() throws {
        guard !isPermanentlyStopped else {
            throw SimulatorControlError(
                code: "worker_permanently_stopped",
                arguments: arguments,
                message: String(
                    localized: "simulator.failure.workerClientStopped",
                    defaultValue: "The Simulator worker client is permanently stopped."
                )
            )
        }
    }

    func broadcast(_ event: SimulatorWorkerEvent, byteCount: Int? = nil) {
        let chargedBytes = byteCount ?? estimatedByteCount(of: event)
        var overflowed: [Int] = []
        var terminated: [Int] = []
        for (identifier, continuation) in subscribers {
            switch continuation.yield(event, byteCount: chargedBytes) {
            case .enqueued:
                break
            case .overflow:
                overflowed.append(identifier)
            case .terminated:
                terminated.append(identifier)
            @unknown default:
                break
            }
        }
        for identifier in Set(overflowed + terminated) {
            subscribers.removeValue(forKey: identifier)?.finish()
        }
        guard !overflowed.isEmpty, child != nil else { return }
        let failure = SimulatorFailure(
            code: "worker_subscriber_queue_overflow",
            message: String(
                localized: "simulator.failure.subscriberQueueOverflow",
                defaultValue: "A Simulator event subscriber exceeded its bounded queue."
            ),
            isRecoverable: true
        )
        for continuation in subscribers.values {
            yield(.message(.failure(failure)), to: continuation)
        }
        discardWorker(intentional: true, clearReplayState: false)
        handleUnexpectedWorkerStop(reason: failure.message)
    }

    func broadcastFailure(_ error: Error, code: String) {
        let failure: SimulatorFailure
        if let simulatorFailure = error as? SimulatorFailure {
            failure = simulatorFailure
        } else if let controlError = error as? SimulatorControlError {
            failure = SimulatorFailure(
                code: controlError.code,
                message: controlError.message,
                isRecoverable: true
            )
        } else {
            failure = SimulatorFailure(code: code, message: String(describing: error), isRecoverable: true)
        }
        broadcast(.message(.failure(failure)))
    }

    private func yield(
        _ event: SimulatorWorkerEvent,
        to continuation: SimulatorWorkerEventStream.Continuation
    ) {
        _ = continuation.yield(event, byteCount: estimatedByteCount(of: event))
    }

    private func estimatedByteCount(of event: SimulatorWorkerEvent) -> Int {
        switch event {
        case .workerStopped:
            return 1
        case let .message(message):
            return (try? JSONEncoder().encode(message).count) ?? 4_096
        }
    }
}
