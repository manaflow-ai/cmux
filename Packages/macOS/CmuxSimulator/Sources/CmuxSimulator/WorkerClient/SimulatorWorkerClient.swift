import Foundation

/// Supervises the isolated Simulator framebuffer/input worker and exposes the
/// supported `simctl` control surface to a native pane.
///
/// Private Simulator frameworks are loaded only by the re-executed child. A
/// child crash closes this client's pipe, clears the frame transport, and spends
/// one automatic restart. A second failure trips a fuse until an explicit
/// activation or ``recover()`` call.
public actor SimulatorWorkerClient: SimulatorPaneClient {
    /// The argument that selects Simulator-worker mode before app startup.
    public static let workerModeArgument = "--cmux-simulator-worker"
    static let maximumSubscriberBufferedBytes = 32 * 1_024 * 1_024
    static let maximumSubscriberEventCount = 1_024
    static let maximumPendingRequestCount = 64

    let executableURL: URL
    let arguments: [String]
    let environment: [String: String]
    let ackTimeout: Duration
    let replayTimeout: Duration
    let launcher: any SimulatorWorkerLaunching
    let sleeper: any SimulatorWorkerSleeping
    let simulatorControl: any SimulatorControlling
    let cameraCleanupCoordinator: SimulatorCameraCleanupCoordinator
    let cameraSharedMemoryToken: String

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
    var requestSubscribers: [UUID: SimulatorWorkerEventStream.Continuation] = [:]
    var nextSubscriberID = 0
    var currentFrameTransport: SimulatorFrameTransportDescriptor?
    var frameTransportSharedMemoryNames: Set<String> = []
    var currentCapabilities: Set<SimulatorCapability> = []
    var currentCapabilitiesAreHydrated = false
    var currentStatus: SimulatorSessionStatus?

    var lastAttachment: SimulatorWorkerInbound?
    var lastGeometry: SimulatorSurfaceGeometry?
    var lastDisplayOrientation: SimulatorOrientation?
    var currentDisplayMetadata: SimulatorDisplayMetadata?
    var cameraReplayConfigurations: [SimulatorCameraConfiguration] = []
    var cameraRequestConfigurations: [UUID: SimulatorCameraConfiguration] = [:]
    var cameraSourceSwitchRequests: [UUID: SimulatorCameraConfiguration] = [:]
    var cameraMirrorRequests: [UUID: SimulatorCameraMirrorMode] = [:]
    var cameraCleanupBundleIdentifiers: Set<String> = []
    var cameraCleanupOwners: [String: UUID] = [:]
    var lastCameraMirrorMode: SimulatorCameraMirrorMode?
    var cameraCleanupTask: Task<SimulatorCameraCleanupResult, Never>?
    var pendingCameraCleanupSnapshot: SimulatorCameraCleanupSnapshot?
    var cameraCleanupFailure: SimulatorFailure?
    var cameraCleanupRevision: UInt64 = 0
    var cameraCleanupPermit = SimulatorCameraCleanupPermit()
    var activePointer: SimulatorPointerEvent?
    var activeScrollIdentifier: UUID?
    var pointerStateRevision: UInt64?
    var heldKeyUsages: Set<UInt32> = []
    var keyStateRevisions: [UInt32: UInt64] = [:]
    var pendingTextInputUsages: [UUID: Set<UInt32>] = [:]
    var pendingInteractiveRequestIdentifiers: Set<UUID> = []
    var deferredMessages: [SimulatorWorkerInbound] = []
    var deferredRequestDeliveries: [UUID: CheckedContinuation<Void, Error>] = [:]
    var heldButtonUsages: Set<SimulatorHIDButtonUsage> = []
    var buttonStateRevisions: [SimulatorHIDButtonUsage: UInt64] = [:]
    var nextInputStateRevision: UInt64 = 1
    var unprovenInputRelease = SimulatorInputReleaseProof()
    var inputReleaseProofs: [UInt64: SimulatorInputReleaseProof] = [:]
    var unprovenConvenienceButtonUsages: Set<SimulatorHIDButtonUsage> = []
    var convenienceButtonProofs: [UInt64: Set<SimulatorHIDButtonUsage>] = [:]
    var replayAwaitingStreaming = false
    var attachmentAwaitingStreaming = false
    var replayMessages: [SimulatorWorkerInbound] = []
    var replayAcknowledgementSequence: UInt64?
    var replayRequestIDs: Set<UUID> = []
    var replayDeadlineToken: UUID?
    var probeNeededAfterReplay = false
    var probeNeededAfterTextInput = false
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
        let cameraSharedMemoryToken = environment[SimulatorCameraSharedMemory.tokenEnvironmentKey]
            ?? UUID().uuidString.lowercased()
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment.merging([
            SimulatorCameraSharedMemory.tokenEnvironmentKey: cameraSharedMemoryToken,
        ]) { existing, _ in existing }
        self.cameraSharedMemoryToken = cameraSharedMemoryToken
        self.ackTimeout = ackTimeout
        self.replayTimeout = .seconds(120)
        self.launcher = SimulatorProcessWorkerLauncher()
        self.sleeper = ContinuousSimulatorWorkerSleeper()
        self.simulatorControl = simulatorControl
        self.cameraCleanupCoordinator = SimulatorCameraCleanupCoordinator()
    }

    init(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        ackTimeout: Duration,
        replayTimeout: Duration = .seconds(120),
        simulatorControl: any SimulatorControlling,
        launcher: any SimulatorWorkerLaunching,
        sleeper: any SimulatorWorkerSleeping = ContinuousSimulatorWorkerSleeper(),
        cameraCleanupCoordinator: SimulatorCameraCleanupCoordinator = SimulatorCameraCleanupCoordinator()
    ) {
        let cameraSharedMemoryToken = environment[SimulatorCameraSharedMemory.tokenEnvironmentKey]
            ?? UUID().uuidString.lowercased()
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment.merging([
            SimulatorCameraSharedMemory.tokenEnvironmentKey: cameraSharedMemoryToken,
        ]) { existing, _ in existing }
        self.cameraSharedMemoryToken = cameraSharedMemoryToken
        self.ackTimeout = ackTimeout
        self.replayTimeout = replayTimeout
        self.simulatorControl = simulatorControl
        self.cameraCleanupCoordinator = cameraCleanupCoordinator
        self.launcher = launcher
        self.sleeper = sleeper
    }

    deinit {
        readerTask?.cancel()
        ackWatchdog?.cancel()
        replayWatchdog?.cancel()
        gracefulTerminationTask?.cancel()
        for name in frameTransportSharedMemoryNames {
            simulatorUnlinkFrameSharedMemory(named: name)
        }
        let deviceIdentifier = simulatorAttachedDeviceIdentifier(from: lastAttachment)
        let bundleIdentifiers = Array(cameraCleanupBundleIdentifiers.union(
            cameraReplayConfigurations.compactMap(\.targetBundleIdentifier)
        ).filter { !$0.isEmpty }).sorted()
        if !crashFuseTripped,
           let deviceIdentifier,
           !bundleIdentifiers.isEmpty {
            let pendingCleanup = cameraCleanupTask
            let simulatorControl = self.simulatorControl
            if let pendingCleanup {
                Task { await pendingCleanup.value }
            } else {
                let cleanupCoordinator = cameraCleanupCoordinator
                let cleanupOwners = cameraCleanupOwners
                Task {
                    _ = await cleanupCoordinator.enqueue(
                        deviceIdentifier: deviceIdentifier,
                        bundleIdentifiers: bundleIdentifiers
                    ) {
                        await cleanSimulatorCameraInjections(
                            deviceIdentifier: deviceIdentifier,
                            bundleIdentifiers: bundleIdentifiers,
                            simulatorControl: simulatorControl,
                            ownershipTokens: cleanupOwners,
                            cleanupCoordinator: cleanupCoordinator
                        )
                    }
                }
            }
        }
        if let child {
            unlinkSimulatorCameraSharedMemory(
                connection: child,
                deviceIdentifier: deviceIdentifier,
                token: cameraSharedMemoryToken
            )
            child.terminate()
        }
    }

    /// Returns installed Simulator devices through the injected control service.
    public func discoverDevices() async throws -> [SimulatorDevice] {
        try requireOpen()
        return try await simulatorControl.discoverDevices()
    }

    /// Boots, waits for, and attaches the isolated worker to a device.
    public func activateDevice(id: String, geometry: SimulatorSurfaceGeometry?) async throws {
        try requireOpen()
        guard await waitForCameraCleanup() else {
            try Task.checkCancellation()
            if let cameraCleanupFailure { throw cameraCleanupFailure }
            throw SimulatorFailure(
                code: "simulator_camera_cleanup_pending",
                message: String(
                    localized: "simulator.failure.cameraCleanupPending",
                    defaultValue: "Camera cleanup is still running. Retry after it finishes."
                ),
                isRecoverable: true
            )
        }
        try requireOpen()
        let discoveredDevices = try? await simulatorControl.discoverDevices()
        try Task.checkCancellation()
        let wasAlreadyBooted = discoveredDevices?
            .first(where: { $0.id == id })?
            .state == .booted
        try await simulatorControl.boot(deviceID: id)
        try Task.checkCancellation()
        if !wasAlreadyBooted {
            try await simulatorControl.waitUntilBooted(deviceID: id)
            try Task.checkCancellation()
        }

        prepareExplicitRecovery()
        await replaceWorkerForAttachmentIfNeeded()
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
                message: String(
                    localized: "simulator.failure.workerAttachFailed",
                    defaultValue: "The isolated worker could not attach to the selected Simulator."
                )
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
            let source = SimulatorWorkerEventStreamSource(
                maximumBufferedBytes: 1,
                maximumBufferedEvents: 1,
                onTermination: {}
            )
            await source.continuation.finish()
            return source.stream
        }
        let identifier = nextSubscriberID
        nextSubscriberID += 1
        let source = SimulatorWorkerEventStreamSource(
            maximumBufferedBytes: Self.maximumSubscriberBufferedBytes,
            maximumBufferedEvents: Self.maximumSubscriberEventCount
        ) { [weak self] in
            Task { [weak self] in
                await self?.removeSubscriber(identifier)
            }
        }
        let continuation = source.continuation
        subscribers[identifier] = continuation
        if let currentFrameTransport {
            await yield(.message(.frameTransport(currentFrameTransport)), to: continuation)
        }
        if currentCapabilitiesAreHydrated {
            await yield(.message(.capabilitiesHydrated(currentCapabilities)), to: continuation)
        } else if !currentCapabilities.isEmpty {
            await yield(.message(.capabilities(currentCapabilities)), to: continuation)
        }
        if let currentStatus {
            await yield(.message(.status(currentStatus)), to: continuation)
        }
        return source.stream
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
        } catch is CancellationError {
            return
        } catch {
            await broadcastFailure(error, code: "worker_send_failed")
        }
    }

    public func acknowledgeFrameTransportAdoption(
        _ descriptor: SimulatorFrameTransportDescriptor
    ) async {
        guard currentFrameTransport == descriptor else { return }
        let obsoleteNames = frameTransportSharedMemoryNames.subtracting([
            descriptor.sharedMemoryName,
        ])
        for name in obsoleteNames {
            simulatorUnlinkFrameSharedMemory(named: name)
            frameTransportSharedMemoryNames.remove(name)
        }
        do {
            try await sendRequired(.acknowledgeFrameTransport(descriptor), probe: false)
        } catch {
            await broadcastFailure(error, code: "frame_transport_adoption_failed")
        }
    }

    /// Clears a tripped crash fuse and relaunches the worker with its last
    /// attachment and geometry.
    public func recover() async throws {
        try requireOpen()
        guard await waitForCameraCleanup() else {
            try Task.checkCancellation()
            if let cameraCleanupFailure { throw cameraCleanupFailure }
            throw SimulatorFailure(
                code: "simulator_camera_cleanup_pending",
                message: String(
                    localized: "simulator.failure.cameraCleanupPending",
                    defaultValue: "Camera cleanup is still running. Retry after it finishes."
                ),
                isRecoverable: true
            )
        }
        try requireOpen()
        prepareExplicitRecovery()
        if child != nil,
           lastAttachment != nil,
           currentStatus != .streaming {
            discardWorker(intentional: true, clearReplayState: false)
        }
        _ = try ensureRunning()
    }

    /// Invalidates the current child process while keeping the client reusable.
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
        if !cleanupAlreadyQueued { await enqueueCameraCleanup(cleanup) }
        _ = await waitForCameraCleanup()
        await broadcast(.workerStopped)
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
        if !cleanupAlreadyQueued { await enqueueCameraCleanup(cleanup) }
        _ = await waitForCameraCleanup()
        for continuation in subscribers.values {
            await continuation.finish()
        }
        subscribers.removeAll()
        for continuation in requestSubscribers.values {
            await continuation.finish()
        }
        requestSubscribers.removeAll()
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
                message: String(
                    localized: "simulator.failure.workerCrashFuse",
                    defaultValue: "The Simulator worker failed twice. Recover the pane before retrying."
                )
            )
        }

        let beginsAttachment: Bool = if case .attach = message { true } else { false }
        if !beginsAttachment, shouldDeferMessage(message) {
            try await deferMessageUntilDelivered(message)
            return
        }
        let data = try JSONEncoder().encode(message)
        for attempt in 0..<2 {
            let connection: SimulatorWorkerConnection
            do {
                if beginsAttachment { attachmentAwaitingStreaming = true }
                connection = try ensureRunning()
            } catch {
                try await prepareRetryAfterTransportFailure(
                    error,
                    attempt: attempt,
                    beginsAttachment: beginsAttachment
                )
                continue
            }
            if !beginsAttachment, shouldDeferMessage(message) {
                try await deferMessageUntilDelivered(message)
                return
            }
            try await prepareCameraCleanupOwnership(for: message)
            do {
                try connection.send(data)
            } catch {
                try await prepareRetryAfterTransportFailure(
                    error,
                    attempt: attempt,
                    beginsAttachment: beginsAttachment
                )
                continue
            }
            await remember(message)
            do {
                if probe { try armResponsivenessProbe() }
            } catch {
                discardWorker(intentional: true, clearReplayState: false)
                await handleUnexpectedWorkerStop(
                    reason: String(
                        localized: "simulator.failure.workerCommandOutcomeUnknown",
                        defaultValue: "The Simulator worker accepted a command but disconnected before confirming its outcome."
                    )
                )
                if beginsAttachment { attachmentAwaitingStreaming = false }
                throw SimulatorControlError(
                    code: "worker_command_outcome_unknown",
                    arguments: arguments,
                    message: String(
                        localized: "simulator.failure.workerCommandOutcomeUnknown",
                        defaultValue: "The Simulator worker accepted a command but disconnected before confirming its outcome."
                    )
                )
            }
            return
        }
    }

}
