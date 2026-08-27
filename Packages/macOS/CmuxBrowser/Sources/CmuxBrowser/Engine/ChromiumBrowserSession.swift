@preconcurrency public import Foundation

/// Owns one out-of-process Chromium instance and its page-level CDP session.
///
/// The actor never embeds Chromium code in cmux. A child-process termination is
/// represented as `.crashed`; the host app remains alive and can call `start()`
/// again to recover the pane.
public actor ChromiumBrowserSession {
    /// Async sequence of lifecycle and page metadata snapshots.
    public typealias StateStream = AsyncStream<ChromiumSessionSnapshot>
    /// Async sequence of encoded screencast frames.
    public typealias FrameStream = AsyncStream<Data>

    private let profileID: UUID
    /// Stable per-pane storage identity for the out-of-process fallback. It
    /// keeps simultaneous child processes from contending on Chromium's
    /// exclusive user-data-directory lock; the in-process CEF adapter uses a
    /// pooled request context when profile sharing is available.
    private let storageID: UUID
    let requestedRemoteDebuggingPort: ChromiumRemoteDebuggingPort
    private let storage: ChromiumOwnedStorage
    private let artifactStore: ChromiumRuntimeArtifactStore
    private let portAllocator: ChromiumLoopbackPortAllocator
    private let startupCoordinator: ChromiumBrowserStartupCoordinator
    private let extensionDirectoriesProvider: @Sendable () -> [URL]
    var process: Process?
    var connection: ChromiumCDPConnection?
    var state: ChromiumSessionState = .stopped
    var currentURL: URL?
    var title: String?
    var canGoBack = false
    var canGoForward = false
    var isLoading = false
    var navigationRevision: UInt64 = 0
    /// CDP frame id for the page target's top-level frame.
    var mainFrameID: String?
    var stateContinuations: [UUID: AsyncStream<ChromiumSessionSnapshot>.Continuation] = [:]
    var frameContinuations: [UUID: FrameStream.Continuation] = [:]
    var internalPort: Int?
    var eventTask: Task<Void, Never>?
    var frameForwardTask: Task<Void, Never>?
    var startupTask: Task<Void, any Error>?
    /// Monotonically changes whenever a start/stop lifecycle is replaced.
    /// Process and CDP callbacks carry their captured identity so a late
    /// callback from an older child can never mutate a restarted pane.
    var lifecycleGeneration: UInt64 = 0
    var startupGeneration: UInt64?
    var connectionGeneration: UInt64?
    var isStopping = false
    /// Waiters keyed by the exact child process identity. `Process.terminate()`
    /// is asynchronous; keeping the reference until its termination callback
    /// arrives lets a replacement session serialize startup without polling or
    /// blocking an executor thread in `waitUntilExit()`.
    var processExitWaiters: [ObjectIdentifier: [UUID: CheckedContinuation<Void, Never>]] = [:]
    /// Children that have been launched but have not delivered their
    /// termination callback. `process` is the current generation's child;
    /// this table also retains a child from a cancelled/replaced startup so a
    /// replacement cannot race Chromium's profile lock. Identity keys keep a
    /// late callback from touching a newer generation.
    var pendingProcesses: [ObjectIdentifier: Process] = [:]
    /// Keeps the duplicated stderr reader alive for the entire child lifetime,
    /// not only until the startup handshake completes.
    var diagnostics: ChromiumProcessDiagnostics?

    /// Creates one managed Chromium child-process session.
    ///
    /// - Parameters:
    ///   - profileID: Logical cmux browser profile that owns the pane storage.
    ///   - storageID: Stable pane identity used by the child-process fallback
    ///     to avoid Chromium profile-lock contention.
    ///   - remoteDebuggingPort: Optional externally advertised loopback CDP port.
    ///   - environment: Explicit filesystem, network, bundle, and process dependencies.
    public init(
        profileID: UUID,
        storageID: UUID = UUID(),
        remoteDebuggingPort: ChromiumRemoteDebuggingPort = .disabled,
        environment: ChromiumBrowserRuntimeEnvironment
    ) {
        let storage = ChromiumOwnedStorage(
            fileManager: environment.fileManager,
            applicationSupportURLProvider: environment.applicationSupportURLProvider,
            bundleIdentifierProvider: environment.bundleIdentifierProvider
        )
        self.profileID = profileID
        self.storageID = storageID
        self.requestedRemoteDebuggingPort = remoteDebuggingPort
        self.storage = storage
        self.artifactStore = ChromiumRuntimeArtifactStore(
            fileManager: environment.fileManager,
            urlSession: environment.runtimeDownloadSession,
            executableOverrideProvider: environment.executableOverrideProvider,
            storage: storage
        )
        self.portAllocator = ChromiumLoopbackPortAllocator()
        self.extensionDirectoriesProvider = environment.extensionDirectoriesProvider
        self.startupCoordinator = ChromiumBrowserStartupCoordinator(
            loopbackSession: environment.loopbackCDPSession,
            startupDeadline: environment.startupDeadline
        )
    }

    deinit {
        startupTask?.cancel()
        for child in pendingProcesses.values {
            child.terminate()
        }
        process?.terminate()
    }

    /// Installs the managed runtime when necessary and starts the child/CDP session.
    ///
    /// - Throws: Runtime installation, child launch, CDP handshake, or cancellation errors.
    public func start() async throws {
        if case .running = state { return }
        if let startupTask {
            try await startupTask.value
            return
        }
        await waitForCurrentProcessExitIfNeeded()
        isStopping = false
        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration
        startupGeneration = generation
        let task = Task { [weak self] in
            guard let self else { return }
            try await self.performStart(generation: generation)
        }
        startupTask = task
        do {
            try await task.value
        } catch {
            if startupGeneration == generation {
                startupTask = nil
                startupGeneration = nil
            }
            throw error
        }
        if startupGeneration == generation {
            startupTask = nil
            startupGeneration = nil
        }
    }

    private func performStart(generation: UInt64) async throws {
        guard isCurrentStartup(generation), process == nil else {
            throw CancellationError()
        }
        state = .starting
        isLoading = true
        publish()
        var launchedProcess: Process?
        var establishedConnection: ChromiumCDPConnection?
        do {
            let executable = try await artifactStore.ensureInstalled()
            guard isCurrentStartup(generation) else { throw CancellationError() }
            try Task.checkCancellation()
            let profileDirectory = try storage.profileDirectory(
                for: profileID,
                storageID: storageID
            )
            let debuggingTransport: ChromiumDebuggingTransport
            if requestedRemoteDebuggingPort.isExternallyAttachable {
                let port: Int
                do {
                    port = try await portAllocator.validate(requestedRemoteDebuggingPort.rawValue)
                } catch CDPError.portUnavailable {
                    // A configured port is a preference, not a reason to
                    // prevent a second pane from starting. Fall back to a
                    // fresh loopback port and publish the actual endpoint.
                    port = try await portAllocator.allocate()
                }
                internalPort = port
                debuggingTransport = .loopback(port: port)
            } else {
                internalPort = nil
                debuggingTransport = .pipe
            }
            let configuration = ChromiumLaunchConfiguration(
                executableURL: executable,
                profileDirectory: profileDirectory,
                debuggingTransport: debuggingTransport,
                extensionDirectories: extensionDirectoriesProvider()
            )
            let child = Process()
            let chromiumArguments = ChromiumLaunchArguments(configuration: configuration).values
            // Create the diagnostics reader before any transport resources so
            // a descriptor setup failure cannot strand a partially-created
            // pipe launch.
            let diagnosticPipe = Pipe()
            let diagnostics = try ChromiumProcessDiagnostics(pipe: diagnosticPipe)
            child.standardError = diagnosticPipe
            let pipeLaunch: ChromiumCDPPipeLaunch?
            switch debuggingTransport {
            case .pipe:
                let launch = try ChromiumCDPPipeLaunch()
                launch.configure(
                    child,
                    chromiumExecutable: configuration.executableURL,
                    chromiumArguments: chromiumArguments
                )
                pipeLaunch = launch
            case .loopback:
                child.executableURL = configuration.executableURL
                child.arguments = chromiumArguments
                child.standardInput = FileHandle.nullDevice
                child.standardOutput = FileHandle.nullDevice
                pipeLaunch = nil
            }
            // Chromium's diagnostics are always drained so child output can
            // never back-pressure the renderer. In TCP mode its authoritative
            // readiness line also signals that the loopback listener is bound.
            child.terminationHandler = { [weak self] process in
                Task { await self?.childTerminated(process: process, status: process.terminationStatus) }
            }
            let processID = ObjectIdentifier(child)
            pendingProcesses[processID] = child
            do {
                try child.run()
            } catch {
                pipeLaunch?.closeFoundationHandles()
                if let pipeLaunch {
                    await pipeLaunch.transport.close()
                }
                pendingProcesses.removeValue(forKey: processID)
                throw error
            }
            pipeLaunch?.closeFoundationHandles()
            launchedProcess = child
            guard isCurrentStartup(generation) else {
                child.terminate()
                throw CancellationError()
            }
            process = child
            self.diagnostics = diagnostics

            let startup = try await startupCoordinator.establishConnection(
                transport: debuggingTransport,
                pipeTransport: pipeLaunch?.transport,
                diagnostics: diagnostics
            )
            let cdp = startup.connection
            let endpoint = startup.endpoint
            establishedConnection = cdp
            guard isCurrentStartup(generation), process === child else {
                cdp.close()
                child.terminate()
                throw CancellationError()
            }
            connection = cdp
            connectionGeneration = generation
            let events = await cdp.events()
            eventTask = Task { [weak self, cdp, generation] in
                for await event in events {
                    await self?.handle(event, connection: cdp, generation: generation)
                }
                await self?.connectionEnded(connection: cdp, generation: generation)
            }
            let screencastFrames = await cdp.screencastFrames()
            frameForwardTask = Task { [weak self, cdp, generation] in
                for await frame in screencastFrames {
                    await self?.forwardScreencastFrame(frame, connection: cdp, generation: generation)
                }
            }
            _ = try await cdp.send(method: "Page.enable")
            _ = try await cdp.send(method: "Runtime.enable")
            _ = try? await cdp.send(
                method: "Page.setLifecycleEventsEnabled",
                parameters: .object(["enabled": .bool(true)])
            )
            await refreshMainFrame(using: cdp)
            // JPEG, not PNG: screencast frames are retina-sized and travel
            // base64-encoded through the CDP JSON stream, so per-frame encode
            // and transfer cost directly bounds interactive frame rate. JPEG
            // at this quality is visually indistinguishable for page content
            // and roughly an order of magnitude smaller/faster than PNG.
            _ = try await cdp.send(method: "Page.startScreencast", parameters: .object([
                "format": .string("jpeg"),
                "quality": .number(75),
                "maxWidth": .number(4096),
                "maxHeight": .number(4096),
                "everyNthFrame": .number(1),
            ]))
            guard isCurrentStartup(generation), process === child, connection === cdp else {
                cdp.close()
                child.terminate()
                throw CancellationError()
            }
            state = .running(endpoint)
            isLoading = false
            await refreshNavigationHistory(using: cdp)
            publish()
        } catch {
            cleanupAfterStartFailure(
                error,
                generation: generation,
                launchedProcess: launchedProcess,
                establishedConnection: establishedConnection
            )
            throw error
        }
    }

    /// Stops CDP and requests asynchronous termination of the managed child.
    public func stop() {
        isStopping = true
        lifecycleGeneration &+= 1
        startupGeneration = nil
        startupTask?.cancel()
        startupTask = nil
        let connectionToClose = connection
        connectionToClose?.close()
        connection = nil
        connectionGeneration = nil
        eventTask?.cancel()
        eventTask = nil
        frameForwardTask?.cancel()
        frameForwardTask = nil
        for continuation in frameContinuations.values { continuation.finish() }
        frameContinuations.removeAll()
        let processToTerminate = process
        // Also terminate detached children from cancelled/replaced startups.
        // Their references stay in `pendingProcesses` until the termination
        // callback, which is the signal used by restart waiters.
        for child in pendingProcesses.values {
            child.terminate()
        }
        processToTerminate?.terminate()
        // Keep the exact process reference until its termination callback. A
        // subsequent `start()`/`stopAndWait()` uses that signal to avoid
        // launching another Chromium instance while the old profile lock is
        // still held, including the small interval after `isRunning` flips
        // false but before Foundation invokes `terminationHandler`.
        internalPort = nil
        mainFrameID = nil
        state = .stopped
        isLoading = false
        canGoBack = false
        canGoForward = false
        publish()
    }

    /// Stops the managed child and waits for its termination callback.
    ///
    /// Chromium owns an on-disk profile lock. This signal-based variant is
    /// used before profile replacement and restart so a new child never races
    /// the old process. It deliberately does not use `waitUntilExit()` because
    /// that would block an app executor thread.
    public func stopAndWait() async {
        guard !pendingProcesses.isEmpty else {
            stop()
            return
        }

        let processIDs = Array(pendingProcesses.keys)
        stop()
        await withTaskGroup(of: Void.self) { group in
            for processID in processIDs {
                group.addTask { [weak self] in
                    await self?.waitForProcessExit(processID)
                }
            }
        }
    }

    func send(method: String, parameters: CDPValue? = nil) async throws -> CDPValue {
        guard let connection else { throw CDPError.notConnected }
        return try await connection.send(method: method, parameters: parameters)
    }

    /// Awaits the exact termination signal for a previous child before a new
    /// generation can launch. This also covers callers that hold the actor
    /// directly (socket automation) rather than going through the AppKit
    /// adapter's prerequisite task.
    private func waitForCurrentProcessExitIfNeeded() async {
        let processIDs = Array(pendingProcesses.keys)
        guard !processIDs.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            for processID in processIDs {
                group.addTask { [weak self] in
                    await self?.waitForProcessExit(processID)
                }
            }
        }
    }

    private func waitForProcessExit(_ processID: ObjectIdentifier) async {
        guard pendingProcesses[processID] != nil else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // Actor isolation keeps the callback from interleaving between the
            // guard and registration, so the termination signal cannot be
            // lost.
            let waiterID = UUID()
            processExitWaiters[processID, default: [:]][waiterID] = continuation
        }
    }

    func childTerminated(process terminatedProcess: Process, status: Int32) {
        let processID = ObjectIdentifier(terminatedProcess)
        pendingProcesses.removeValue(forKey: processID)
        guard let currentProcess = self.process, currentProcess === terminatedProcess else {
            // A failed startup may have detached the process reference before
            // the callback arrives. There can still be a waiter registered by
            // `stopAndWait()`, so always finish that exact identity.
            finishProcessExit(processID)
            return
        }
        self.process = nil
        diagnostics = nil
        connection?.close()
        connection = nil
        connectionGeneration = nil
        eventTask?.cancel()
        eventTask = nil
        frameForwardTask?.cancel()
        frameForwardTask = nil
        internalPort = nil
        isLoading = false
        mainFrameID = nil
        state = isStopping ? .stopped : .crashed(status)
        publish()
        finishProcessExit(processID)
    }

    private func finishProcessExit(_ processID: ObjectIdentifier) {
        guard let waiters = processExitWaiters.removeValue(forKey: processID) else { return }
        for continuation in waiters.values {
            continuation.resume()
        }
    }

    private func refreshMainFrame(using connection: ChromiumCDPConnection) async {
        guard let value = try? await connection.send(method: "Page.getFrameTree"),
              case .object(let object) = value,
              case .object(let frameTree)? = object["frameTree"],
              case .object(let frame)? = frameTree["frame"] else {
            return
        }
        if let frameID = frame["id"]?.stringValue {
            mainFrameID = frameID
        }
        if let url = frame["url"]?.stringValue, let parsedURL = URL(string: url) {
            currentURL = parsedURL
        }
        if let frameTitle = frame["name"]?.stringValue, !frameTitle.isEmpty {
            title = frameTitle
        }
    }
}
