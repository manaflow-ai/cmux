@preconcurrency public import Foundation
import Darwin

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
    private let extensionStore: ChromiumExtensionStore
    /// Main-actor policy used to pause and vet top-level document requests.
    private let navigationPolicyHandler: BrowserEngineNavigationPolicyHandler?
    /// Renderer-side observer used to mirror SPA title mutations.
    let documentTitleObservation = ChromiumDocumentTitleObservation()
    var process: Process?
    /// Native OWL Mojo transport used by the Content Shell runtime.
    var owlRuntime: OwlFreshRuntime?
    var owlPollTask: Task<Void, Never>?
    var owlNavigationReadinessTask: Task<Void, Never>?
    var owlHistory: OwlNavigationHistoryState?
    var owlNavigationIntent: OwlNavigationIntent?
    var owlNavigationSawLoadingEvent = false
    var owlNavigationBaselineDocumentEpoch: Double?
    var owlCurrentDocumentEpoch: Double?
    /// Identifies the most recent OWL completion whose requested destination
    /// may have been redirected. The request URL is retained so an older
    /// waiter cannot complete from an unrelated later navigation.
    var owlLastRedirectNavigationRevision: UInt64?
    var owlLastRedirectNavigationTarget: URL?
    var nativeSurfaceContextID: UInt32?
    var connection: ChromiumCDPConnection?
    var state: ChromiumSessionState = .stopped
    var currentURL: URL?
    var title: String?
    var canGoBack = false
    var canGoForward = false
    var backHistoryURLs: [URL] = []
    var forwardHistoryURLs: [URL] = []
    var isLoading = false
    var navigationRevision: UInt64 = 0
    /// CDP frame id for the page target's top-level frame.
    var mainFrameID: String?
    var stateContinuations: [UUID: AsyncStream<ChromiumSessionSnapshot>.Continuation] = [:]
    var frameContinuations: [UUID: FrameStream.Continuation] = [:]
    var internalPort: Int?
    var eventTask: Task<Void, Never>?
    /// Actor-owned request interceptor for streamed Chromium navigations.
    var navigationInterceptor: ChromiumNavigationInterceptor?
    var frameForwardTask: Task<Void, Never>?
    /// Reconciles the CDP screencast with the latest pane visibility request.
    var screencastUpdateTask: Task<Void, Never>?
    /// Whether the AppKit host currently needs viewport frames.
    var isPaneVisible = false
    /// Whether `Page.startScreencast` has successfully been applied to the
    /// current CDP connection.
    var isScreencastActive = false
    var startupTask: Task<Void, any Error>?
    /// Monotonically changes whenever a start/stop lifecycle is replaced.
    /// Process and CDP callbacks carry their captured identity so a late
    /// callback from an older child can never mutate a restarted pane.
    var lifecycleGeneration: UInt64 = 0
    var startupGeneration: UInt64?
    var connectionGeneration: UInt64?
    var isStopping = false
    private static let processExitDeadline: Duration = .seconds(15)
    private static let processKillGrace: Duration = .seconds(3)
    /// Waiters keyed by the exact child process identity. `Process.terminate()`
    /// is asynchronous; keeping the reference until its termination callback
    /// arrives lets a replacement session serialize startup without polling or
    /// blocking an executor thread in `waitUntilExit()`.
    var processExitWaiters: [ObjectIdentifier: [UUID: CheckedContinuation<Void, Never>]] = [:]
    private var cancelledProcessExitWaiters: Set<UUID> = []
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
        environment: ChromiumBrowserRuntimeEnvironment,
        navigationPolicyHandler: BrowserEngineNavigationPolicyHandler? = nil
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
        self.extensionStore = ChromiumExtensionStore(storage: storage)
        self.navigationPolicyHandler = navigationPolicyHandler
        self.startupCoordinator = ChromiumBrowserStartupCoordinator(
            loopbackSession: environment.loopbackCDPSession,
            startupDeadline: environment.startupDeadline
        )
    }

    deinit {
        startupTask?.cancel()
        screencastUpdateTask?.cancel()
        owlPollTask?.cancel()
        owlNavigationReadinessTask?.cancel()
        owlNavigationReadinessTask = nil
        owlRuntime = nil
        owlHistory = nil
        owlNavigationIntent = nil
        owlNavigationSawLoadingEvent = false
        owlNavigationBaselineDocumentEpoch = nil
        owlCurrentDocumentEpoch = nil
        owlLastRedirectNavigationRevision = nil
        owlLastRedirectNavigationTarget = nil
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
        try await waitForCurrentProcessExitIfNeeded()
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

    /// Whether this session is backed by the native OWL surface transport.
    public func usesNativeOWL() -> Bool { owlRuntime != nil || (state == .running(nil) && process == nil && connection == nil) }

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
            let extensionDirectories = try await extensionStore.prepare(
                directories: extensionDirectoriesProvider().map(\.path),
                profileID: profileID
            )
            if executable.lastPathComponent == "Content Shell" {
                try await performOwlStart(
                    executable: executable,
                    profileDirectory: profileDirectory,
                    extensionDirectories: extensionDirectories,
                    generation: generation
                )
                return
            }
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
                extensionDirectories: extensionDirectories
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
            await installDocumentTitleObservation(using: cdp)
            if let navigationPolicyHandler {
                let interceptor = ChromiumNavigationInterceptor(
                    policyHandler: navigationPolicyHandler
                )
                navigationInterceptor = interceptor
                try await interceptor.install(connection: cdp)
            }
            _ = try? await cdp.send(
                method: "Page.setLifecycleEventsEnabled",
                parameters: .object(["enabled": .bool(true)])
            )
            await refreshMainFrame(using: cdp)
            await refreshTitle(using: cdp)
            // Frame delivery is demand-driven by the AppKit host. Hidden
            // panes do not start a screencast, which avoids retaining and
            // decoding viewport images while a tab is offscreen.
            isScreencastActive = false
            startScreencastUpdateIfNeeded()
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

    /// Starts the forked Content Shell through its native Mojo C ABI.
    ///
    /// OWL owns the renderer and GPU process; cmux receives only compositor
    /// context IDs and forwards input through the same isolated session.
    private func performOwlStart(
        executable: URL,
        profileDirectory: URL,
        extensionDirectories: [URL],
        generation: UInt64
    ) async throws {
        let initialURL = currentURL ?? URL(string: "about:blank")!
        let owlShell = try OwlFreshRuntime.shellExecutable(
            for: executable,
            extensionDirectories: extensionDirectories,
            wrapperDirectory: profileDirectory
        )
        let runtime = try OwlFreshRuntime(
            shell: owlShell,
            runtimeShell: executable,
            initialURL: initialURL,
            profile: profileDirectory
        ) { [weak self] event in
            Task { await self?.handleOwlEvent(event, generation: generation) }
        }
        guard isCurrentStartup(generation) else {
            throw CancellationError()
        }
        owlRuntime = runtime
        nativeSurfaceContextID = nil
        state = .running(nil)
        // The Content Shell is created with this initial document. A later
        // adapter-provided initial URL goes through the normal OWL navigation
        // operation and readiness monitor.
        currentURL = initialURL
        isLoading = false
        owlHistory = OwlNavigationHistoryState(initialURL: initialURL)
        owlNavigationIntent = nil
        owlNavigationSawLoadingEvent = false
        owlNavigationBaselineDocumentEpoch = nil
        owlCurrentDocumentEpoch = owlDocumentEpoch(runtime: runtime)
        syncOwlHistorySnapshot()
        publish()
        owlPollTask = Task.detached(priority: .userInitiated) { [runtime] in
            while !Task.isCancelled {
                runtime.poll()
            }
        }
    }

    private func handleOwlEvent(_ event: OwlFreshRuntime.Event, generation: UInt64) {
        guard lifecycleGeneration == generation, owlRuntime != nil else { return }
        switch event.kind {
        case 3, 6:
            if event.contextID != 0 { nativeSurfaceContextID = event.contextID }
        case 4:
            let eventURL = event.url.flatMap(URL.init(string:))
            if let eventTitle = event.title, !eventTitle.isEmpty {
                title = eventTitle
            }
            if event.loading {
                // OWL emits this edge synchronously from Navigate. It is also
                // the guard that prevents a stale title-only event from
                // completing a newer operation.
                owlNavigationSawLoadingEvent = true
                isLoading = true
                if owlNavigationIntent == nil, let eventURL {
                    // Renderer-started navigations have no caller to start
                    // the fallback monitor. The loading callback is the
                    // operation's start edge; readiness still verifies the
                    // complete document before committing it. This applies to
                    // same-URL reloads and form submissions as well as URL changes.
                    beginOwlNavigation(
                        .rendererDestination(eventURL),
                        baselineDocumentEpoch: owlCurrentDocumentEpoch
                    )
                    owlNavigationSawLoadingEvent = true
                    startOwlNavigationReadinessMonitor()
                }
            } else if owlNavigationIntent == nil, let eventURL,
                      !Self.matches(url: currentURL, target: eventURL) {
                // A terminal callback for an OWL operation is only a hint:
                // the readiness monitor must prove that a newer document is
                // complete before it commits the operation. Renderer-side
                // navigations without a pending cmux intent can still be
                // committed directly here.
                currentURL = eventURL
                owlHistory?.commitDestination(eventURL)
                syncOwlHistorySnapshot()
                isLoading = false
                navigationRevision &+= 1
            }
        case 5:
            teardownOwlRuntime()
            state = .crashed(-1)
            isLoading = false
        default:
            break
        }
        publish()
    }

    func teardownOwlRuntime() {
        owlNavigationReadinessTask?.cancel()
        owlNavigationReadinessTask = nil
        owlPollTask?.cancel()
        owlPollTask = nil
        owlRuntime = nil
        owlHistory = nil
        owlNavigationIntent = nil
        owlNavigationSawLoadingEvent = false
        owlNavigationBaselineDocumentEpoch = nil
        owlCurrentDocumentEpoch = nil
        nativeSurfaceContextID = nil
    }

    /// Stops CDP and requests asynchronous termination of the managed child.
    public func stop() {
        isStopping = true
        lifecycleGeneration &+= 1
        startupGeneration = nil
        startupTask?.cancel()
        startupTask = nil
        owlPollTask?.cancel()
        owlPollTask = nil
        owlNavigationReadinessTask?.cancel()
        owlNavigationReadinessTask = nil
        owlRuntime = nil
        owlHistory = nil
        owlNavigationIntent = nil
        owlNavigationSawLoadingEvent = false
        owlNavigationBaselineDocumentEpoch = nil
        owlCurrentDocumentEpoch = nil
        nativeSurfaceContextID = nil
        let connectionToClose = connection
        connectionToClose?.close()
        connection = nil
        connectionGeneration = nil
        navigationInterceptor = nil
        eventTask?.cancel()
        eventTask = nil
        frameForwardTask?.cancel()
        frameForwardTask = nil
        screencastUpdateTask?.cancel()
        screencastUpdateTask = nil
        isScreencastActive = false
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
        backHistoryURLs.removeAll(keepingCapacity: false)
        forwardHistoryURLs.removeAll(keepingCapacity: false)
        publish()
    }

    /// Stops the managed child and waits for its termination callback.
    ///
    /// Chromium owns an on-disk profile lock. This signal-based variant is
    /// used before profile replacement and restart so a new child never races
    /// the old process. It deliberately does not use `waitUntilExit()` because
    /// that would block an app executor thread.
    @discardableResult
    public func stopAndWait() async -> Bool {
        let processIDs = Array(pendingProcesses.keys)
        let owlRuntimeToStop = owlRuntime
        let owlPollTaskToStop = owlPollTask
        let owlReadinessTaskToStop = owlNavigationReadinessTask
        stop()
        owlPollTaskToStop?.cancel()
        owlReadinessTaskToStop?.cancel()
        await owlPollTaskToStop?.value
        await owlReadinessTaskToStop?.value
        let owlExited = if let owlRuntimeToStop {
            await owlRuntimeToStop.shutdownAndWait()
        } else {
            true
        }
        guard !processIDs.isEmpty else { return owlExited }

        var allExited = true
        for processID in processIDs {
            if await waitForProcessExit(processID, timeout: Self.processExitDeadline) {
                continue
            }
            // Escalate once the bounded graceful-stop deadline expires, while
            // retaining the process identity until its termination callback.
            forceKill(processID)
            if !(await waitForProcessExit(processID, timeout: Self.processKillGrace)) {
                allExited = false
            }
        }
        return owlExited && allExited
    }

    /// Enables or suspends CDP viewport-frame delivery for the pane host.
    ///
    /// The preference is retained across a child restart and applied as soon
    /// as the replacement connection is ready. Turning it off sends
    /// `Page.stopScreencast`; no page or profile state is discarded.
    ///
    /// - Parameter enabled: Whether the pane currently needs rendered frames.
    public func setScreencastEnabled(_ enabled: Bool) {
        isPaneVisible = enabled
        startScreencastUpdateIfNeeded()
    }

    private func startScreencastUpdateIfNeeded() {
        guard !isStopping,
              connection != nil,
              screencastUpdateTask == nil,
              ChromiumScreencastTransition(
                  isPaneVisible: isPaneVisible,
                  isScreencastActive: isScreencastActive
              ).method != nil else {
            return
        }
        screencastUpdateTask = Task { [weak self] in
            await self?.drainScreencastUpdates()
        }
    }

    private func drainScreencastUpdates() async {
        defer { screencastUpdateTask = nil }
        while !Task.isCancelled,
              let connection,
              let method = ChromiumScreencastTransition(
                  isPaneVisible: isPaneVisible,
                  isScreencastActive: isScreencastActive
              ).method {
            let targetVisible = isPaneVisible
            let parameters: CDPValue? = targetVisible
                ? .object([
                    "format": .string("jpeg"),
                    "quality": .number(75),
                    "maxWidth": .number(4096),
                    "maxHeight": .number(4096),
                    "everyNthFrame": .number(1),
                ])
                : nil
            do {
                _ = try await connection.send(method: method, parameters: parameters)
            } catch is CancellationError {
                return
            } catch {
                // Connection teardown resets the active bit; the next child
                // generation reconciles the latest visibility preference.
                return
            }
            guard self.isCurrentConnection(connection) else { return }
            isScreencastActive = targetVisible
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
    private func waitForCurrentProcessExitIfNeeded() async throws {
        let processIDs = Array(pendingProcesses.keys)
        guard !processIDs.isEmpty else { return }
        var failedProcessIDs: [ObjectIdentifier] = []
        for processID in processIDs {
            if await waitForProcessExit(processID, timeout: Self.processExitDeadline) {
                continue
            }
            forceKill(processID)
            if !(await waitForProcessExit(processID, timeout: Self.processKillGrace)) {
                failedProcessIDs.append(processID)
            }
        }
        guard failedProcessIDs.isEmpty else {
            throw CDPError.disconnected(ChromiumBrowserDiagnostic.connectionClosed.message)
        }
    }

    private func waitForProcessExit(
        _ processID: ObjectIdentifier,
        timeout: Duration
    ) async -> Bool {
        guard pendingProcesses[processID] != nil else { return true }
        let waiterID = UUID()
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask { [weak self] in
                await self?.waitForProcessExitSignal(processID, waiterID: waiterID) ?? true
            }
            group.addTask {
                do {
                    try await Task.sleep(for: timeout)
                    return false
                } catch {
                    return true
                }
            }
            let result = await group.next() ?? true
            group.cancelAll()
            if !result {
                cancelProcessExitWaiter(processID, waiterID: waiterID)
            }
            return result
        }
    }

    private func waitForProcessExitSignal(
        _ processID: ObjectIdentifier,
        waiterID: UUID
    ) async -> Bool {
        guard pendingProcesses[processID] != nil else { return true }
        await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if cancelledProcessExitWaiters.remove(waiterID) != nil {
                    continuation.resume()
                } else if pendingProcesses[processID] == nil {
                    continuation.resume()
                } else {
                    processExitWaiters[processID, default: [:]][waiterID] = continuation
                }
            }
        }, onCancel: {
            Task { await self.cancelProcessExitWaiter(processID, waiterID: waiterID) }
        })
        return true
    }

    private func cancelProcessExitWaiter(
        _ processID: ObjectIdentifier,
        waiterID: UUID
    ) {
        guard let waiter = processExitWaiters[processID]?.removeValue(forKey: waiterID) else {
            if pendingProcesses[processID] != nil {
                cancelledProcessExitWaiters.insert(waiterID)
            }
            return
        }
        if processExitWaiters[processID]?.isEmpty == true {
            processExitWaiters.removeValue(forKey: processID)
        }
        waiter.resume()
    }

    private func forceKill(_ processID: ObjectIdentifier) {
        guard let process = pendingProcesses[processID], process.processIdentifier > 0 else { return }
        _ = Darwin.kill(process.processIdentifier, SIGKILL)
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
        navigationInterceptor = nil
        eventTask?.cancel()
        eventTask = nil
        frameForwardTask?.cancel()
        frameForwardTask = nil
        screencastUpdateTask?.cancel()
        screencastUpdateTask = nil
        isScreencastActive = false
        internalPort = nil
        isLoading = false
        mainFrameID = nil
        backHistoryURLs.removeAll(keepingCapacity: false)
        forwardHistoryURLs.removeAll(keepingCapacity: false)
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

    /// Installs the renderer-side title observer for the current page target.
    /// The hook is best-effort because older managed Chromium artifacts may not
    /// implement `Runtime.addBinding`; regular load events still provide title
    /// snapshots in that case.
    private func installDocumentTitleObservation(
        using connection: ChromiumCDPConnection
    ) async {
        _ = try? await connection.send(
            method: "Runtime.addBinding",
            parameters: documentTitleObservation.bindingParameters
        )
        _ = try? await connection.send(
            method: "Page.addScriptToEvaluateOnNewDocument",
            parameters: documentTitleObservation.scriptParameters
        )
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
        // Frame.name is the target/window name, not the document title. Read
        // the actual title through Runtime.evaluate after the frame snapshot.
    }
}
