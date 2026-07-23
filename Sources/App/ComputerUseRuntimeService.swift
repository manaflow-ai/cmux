import AppKit
import CmuxControlSocket
import Darwin
import Foundation
import Security

/// The single app-side owner of the standalone Computer Use helper lifecycle.
///
/// The main cmux process never calls TCC-protected APIs and never executes the
/// driver binary. It installs the helper, launches that app through
/// LaunchServices, and reads permission status exclusively over the daemon UDS.
@MainActor
final class ComputerUseRuntimeService {
    static let helperAppName = "cmux Computer Use"

    private static let systemSettingsBundleIdentifier = "com.apple.systempreferences"

    let paths: ComputerUseRuntimePaths
    let applicationName: String
    let stateAuthenticationKey: Data

    private let bundledHelperAppURL: URL?
    private let transport: SocketTransport
    private var installedHelperURL: URL?
    private var helperLifecycleTask: Task<Void, Never>?
    private var helperLifecycleCancellationActions: [Int: @Sendable () -> Void] = [:]
    private var helperLifecycleGeneration = 0
    private var helperTerminationObservationTask: Task<Void, Never>?
    private var helperHealthTask: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?
    private var cachedStatus = ComputerUsePermissionStatus.unknown
    private var permissionRefreshGeneration = 0
    private var acceptsNewLaunches = true
    private var desiredEnabled = false
    private var runningHelperProcessIdentifier: pid_t?
    private var runningHelperProcessIdentity: AgentPIDProcessIdentity?
    private var missedHelperHealthChecks = 0
    private var expectedTerminationProcessIdentifiers: Set<pid_t> = []

    init(
        bundle: Bundle = .main,
        paths: ComputerUseRuntimePaths = ComputerUseRuntimePaths(),
        transport: SocketTransport = SocketTransport()
    ) {
        self.paths = paths
        self.transport = transport
        stateAuthenticationKey = Self.makeStateAuthenticationKey()
        let nestedURL = bundle.bundleURL
            .appendingPathComponent("Contents/Library/\(Self.helperAppName).app", isDirectory: true)
        applicationName = Self.helperAppName
        if FileManager.default.fileExists(atPath: nestedURL.path) {
            bundledHelperAppURL = nestedURL
        } else {
            bundledHelperAppURL = nil
        }
        startObservingHelperTermination()
    }

    deinit {
        for cancel in helperLifecycleCancellationActions.values {
            cancel()
        }
        helperLifecycleTask?.cancel()
        helperTerminationObservationTask?.cancel()
        helperHealthTask?.cancel()
        recoveryTask?.cancel()
    }

    var helperAppURL: URL? {
        installedHelperURL
    }

    /// The branded helper icon used while its top-level copy is still installing.
    ///
    /// Keep `helperAppURL` restricted to the installed helper because permission
    /// interactions need that independently registered URL. Presentation can use
    /// the identical nested app immediately, avoiding a generic first frame.
    var presentationIcon: NSImage? {
        let candidate = installedHelperURL ?? bundledHelperAppURL
        guard let candidate else { return nil }
        return NSWorkspace.shared.icon(forFile: candidate.path)
    }

    var stateDirectoryURL: URL {
        paths.stateDirectoryURL
    }

    func status() -> (accessibility: Bool, screenRecording: Bool) {
        (cachedStatus.accessibility, cachedStatus.screenRecording)
    }

    var permissionStatusIsKnown: Bool {
        cachedStatus.isKnown
    }

    /// Emits coalesced filesystem changes from the user's TCC database.
    ///
    /// The event is only a refresh trigger; the helper remains the sole
    /// authority for whether either permission is actually granted.
    nonisolated func permissionStatusEvents() -> AsyncStream<Void> {
        let directoryURL = paths.permissionDatabaseDirectoryURL
        return Self.mergedFileSystemEvents(at: [
            directoryURL,
            directoryURL.appendingPathComponent("TCC.db"),
        ], fallbackInterval: .milliseconds(500))
    }

    /// Reconciles the helper daemon with the live `computerUse.enabled` setting.
    func setEnabled(_ newValue: Bool) async {
        guard acceptsNewLaunches, !Task.isCancelled else { return }
        permissionRefreshGeneration &+= 1
        desiredEnabled = newValue
        if newValue {
            await startIfNeeded()
            startMonitoringHelperHealth()
        } else {
            helperHealthTask?.cancel()
            helperHealthTask = nil
            missedHelperHealthChecks = 0
            recoveryTask?.cancel()
            recoveryTask = nil
            await serializeHelperLifecycle(cancelledResult: ()) { [weak self] in
                guard let self else { return }
                _ = await self.stopDaemon()
            }
            try? FileManager.default.removeItem(at: paths.authenticationTokenFileURL)
            cachedStatus = .unknown
        }
    }

    /// Installs the nested helper at its independently registered top-level URL.
    @discardableResult
    func ensureStandaloneHelperInstalled() async -> URL? {
        await serializeHelperLifecycle(cancelledResult: nil as URL?) { [weak self] in
            guard let self else { return nil }
            return await self.ensureStandaloneHelperInstalledWithinLifecycle()
        }
    }

    /// Passively reads fresh TCC status from an already-running helper.
    ///
    /// Settings and onboarding call this while rendering and after returning
    /// from System Settings. It must never install, start, stop, or restart the
    /// helper: opening Settings is not authorization to override the enabled
    /// preference or interrupt an active Computer Use request.
    @discardableResult
    func refreshHelperStatus() async -> (accessibility: Bool, screenRecording: Bool) {
        guard acceptsNewLaunches, !Task.isCancelled else { return status() }
        permissionRefreshGeneration &+= 1
        let generation = permissionRefreshGeneration
        let enabledAtStart = desiredEnabled
        let paths = self.paths
        let transport = self.transport

        // TCC's "Quit & Reopen" briefly replaces the helper with a process that
        // has not yet rebound cmux's serve socket. Waiting belongs outside the
        // helper-lifecycle chain: recovery needs that same chain to terminate
        // the transient process and launch the correctly configured daemon.
        let latest = enabledAtStart
            ? await Self.waitForPermissionStatus(
                paths: paths,
                transport: transport
            )
            : await Self.queryPermissionStatus(
                paths: paths,
                transport: transport
            )
        guard
            !Task.isCancelled,
            acceptsNewLaunches,
            generation == permissionRefreshGeneration,
            desiredEnabled == enabledAtStart
        else {
            return status()
        }
        cachedStatus = cachedStatus.applyingProbeResult(latest)
        return status()
    }

    func revealHelperInFinder() {
        Task { @MainActor [weak self] in
            guard let self, let url = await ensureStandaloneHelperInstalled() else { return }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    func openAccessibilitySettings() async -> Bool {
        await openSystemSettings(
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        )
    }

    func openScreenRecordingSettings() async -> Bool {
        await openSystemSettings(
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        )
    }

    /// Ends one exact cmux-managed driver session through the authenticated
    /// helper that owns its state and cursor.
    func endDriverSession(_ driverSessionID: String) async -> Bool {
        guard ComputerUseSessionScope.isManagedDriverSessionID(driverSessionID)
        else {
            return false
        }
        return await serializeHelperLifecycle(cancelledResult: false) { [weak self] in
            guard
                let self,
                self.desiredEnabled,
                self.acceptsNewLaunches,
                let expectedPeerIdentity = self.runningHelperProcessIdentity,
                AgentPIDProcessIdentity(pid: expectedPeerIdentity.pid)
                    == expectedPeerIdentity
            else {
                return false
            }
            guard let response = await Self.sendDaemonRequest(
                [
                    "method": "call",
                    "name": "end_session",
                    "args": ["session": driverSessionID],
                ],
                paths: self.paths,
                transport: self.transport,
                timeout: 3,
                expectedPeerIdentity: expectedPeerIdentity
            ) else {
                return false
            }
            return response["ok"] as? Bool == true
        }
    }

    private func startIfNeeded() async {
        await serializeHelperLifecycle(cancelledResult: ()) { [weak self] in
            guard let self else { return }
            await self.startIfNeededWithinLifecycle()
        }
    }

    private func serializeHelperLifecycle<Result: Sendable>(
        cancelledResult: Result,
        _ operation: @escaping @MainActor @Sendable () async -> Result
    ) async -> Result {
        let predecessor = helperLifecycleTask
        helperLifecycleGeneration &+= 1
        let generation = helperLifecycleGeneration
        let operationTask = Task { @MainActor in
            await predecessor?.value
            guard !Task.isCancelled else { return cancelledResult }
            return await operation()
        }
        helperLifecycleCancellationActions[generation] = {
            operationTask.cancel()
        }
        helperLifecycleTask = Task { @MainActor in
            _ = await operationTask.value
        }
        let result = await withTaskCancellationHandler {
            await operationTask.value
        } onCancel: {
            operationTask.cancel()
        }
        helperLifecycleCancellationActions.removeValue(forKey: generation)
        if generation == helperLifecycleGeneration {
            helperLifecycleTask = nil
        }
        return result
    }

    private func ensureStandaloneHelperInstalledWithinLifecycle() async -> URL? {
        guard acceptsNewLaunches, !Task.isCancelled, prepareRuntimeForLaunch() else { return nil }
        guard let bundledHelperAppURL else { return nil }
        let destination = paths.installedHelperAppURL
        let currentCheckTask = Task.detached(priority: .userInitiated) {
            Self.helperIsCurrent(nested: bundledHelperAppURL, destination: destination)
        }
        let isCurrent = await withTaskCancellationHandler {
            await currentCheckTask.value
        } onCancel: {
            currentCheckTask.cancel()
        }
        guard acceptsNewLaunches, !Task.isCancelled else { return nil }
        if isCurrent {
            installedHelperURL = destination
            return destination
        }

        guard await stopDaemon(), acceptsNewLaunches, !Task.isCancelled else { return nil }
        let directory = paths.installedHelperDirectoryURL
        let installationTask = Task.detached(priority: .userInitiated) {
            Self.installHelper(
                nested: bundledHelperAppURL,
                destination: destination,
                directory: directory
            )
        }
        let result = await withTaskCancellationHandler {
            await installationTask.value
        } onCancel: {
            installationTask.cancel()
        }
        guard acceptsNewLaunches, !Task.isCancelled else { return nil }
        installedHelperURL = result
        return result
    }

    private func startIfNeededWithinLifecycle() async {
        guard acceptsNewLaunches, !Task.isCancelled else { return }
        guard let helperURL = await ensureStandaloneHelperInstalledWithinLifecycle() else { return }
        guard acceptsNewLaunches, !Task.isCancelled else { return }
        if await Self.isDaemonListening(paths: paths, transport: transport),
           await configureStateAuthentication() {
            return
        }
        guard acceptsNewLaunches, !Task.isCancelled else { return }
        // A failed probe does not prove that an older helper exited. Stop and
        // verify the exact installed helper before launching a replacement, or a
        // wedged process can retain TCC privileges beside the new daemon.
        guard await stopDaemon(), acceptsNewLaunches, !Task.isCancelled else { return }
        guard await launchHelper(at: helperURL) else { return }
        guard acceptsNewLaunches, !Task.isCancelled else { return }
        guard await Self.waitForDaemonStart(paths: paths, transport: transport)
        else {
            return
        }
        guard await configureStateAuthentication() else {
            _ = await stopDaemon()
            return
        }
    }

    private func stopDaemon() async -> Bool {
        let helperURL = installedHelperURL ?? paths.installedHelperAppURL
        var processIdentifiers = Set(
            runningHelperApplications(at: helperURL).keys
        )
        if let identity = runningHelperProcessIdentity,
           AgentPIDProcessIdentity(pid: identity.pid) == identity {
            processIdentifiers.insert(identity.pid)
        }
        if await Self.isDaemonListening(paths: paths, transport: transport) {
            recordExpectedTerminationOfRunningHelper(at: helperURL)
            _ = await Self.sendDaemonRequest(
                ["method": "shutdown"],
                paths: paths,
                transport: transport,
                timeout: 2
            )
            if await Self.waitForDaemonStop(paths: paths, transport: transport) {
                if processIdentifiers.isEmpty {
                    clearTrackedHelperProcess()
                    return true
                }
                if await waitForHelperProcessesToExit(
                    processIdentifiers,
                    helperURL: helperURL,
                    attempts: 10
                ) {
                    clearTrackedHelperProcess()
                    return true
                }
            }
        }

        // A failed probe is ambiguous: the helper may be gone, or it may be
        // wedged while retaining TCC privileges and the current bearer token.
        // Fail closed by SIGKILLing only processes whose bundle URL exactly
        // matches our independently installed helper, then revoke its socket.
        let terminated = await terminateRunningHelperAndWait(at: helperURL)
        try? FileManager.default.removeItem(at: paths.daemonSocketURL)
        if terminated {
            clearTrackedHelperProcess()
        }
        return terminated
    }

    private func launchHelper(at helperURL: URL) async -> Bool {
        guard acceptsNewLaunches, !Task.isCancelled, prepareRuntimeForLaunch() else { return false }
        guard let launch = ComputerUseHelperLaunchConfiguration(paths: paths) else {
            return false
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.createsNewApplicationInstance = true
        configuration.arguments = launch.arguments
        configuration.environment = launch.environment
        let launchedProcessIdentifier: pid_t? = await withCheckedContinuation { continuation in
            NSWorkspace.shared.openApplication(
                at: helperURL,
                configuration: configuration,
                completionHandler: Self.makeHelperLaunchCompletion(
                    continuation: continuation
                )
            )
        }
        guard let launchedProcessIdentifier else { return false }
        guard let launchedProcessIdentity = AgentPIDProcessIdentity(
            pid: launchedProcessIdentifier
        ) else {
            if let application = NSRunningApplication(
                processIdentifier: launchedProcessIdentifier
            ) {
                _ = application.forceTerminate()
            }
            return false
        }
        runningHelperProcessIdentifier = launchedProcessIdentifier
        runningHelperProcessIdentity = launchedProcessIdentity
        guard acceptsNewLaunches, !Task.isCancelled else {
            terminateRunningHelper(at: helperURL)
            return false
        }
        return true
    }

    private func configureStateAuthentication() async -> Bool {
        guard
            stateAuthenticationKey.count == 32,
            let runningHelperProcessIdentity
        else {
            return false
        }
        guard let response = await Self.sendDaemonRequest(
            [
                "method": "configure_state_authentication",
                "args": [
                    "key_base64": stateAuthenticationKey.base64EncodedString(),
                ],
            ],
            paths: paths,
            transport: transport,
            timeout: 2,
            expectedPeerIdentity: runningHelperProcessIdentity
        ) else {
            return false
        }
        let configured =
            response["ok"] as? Bool == true
                && (response["result"] as? [String: Any])?[
                    "state_authentication"
                ] as? Bool == true
        return configured
    }

    /// Creates and validates the private runtime before any helper launch.
    /// Existing symlinks, foreign ownership, or permission failures abort the
    /// launch instead of falling through to a predictable shared `/tmp` path.
    func prepareRuntimeForLaunch() -> Bool {
        guard acceptsNewLaunches else { return false }
        let fileManager = FileManager.default
        let computerUseParent = paths.computerUseDirectoryURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: computerUseParent, withIntermediateDirectories: true)
        } catch {
            return false
        }

        let privateDirectories = [
            paths.runtimeDirectoryURL.deletingLastPathComponent(),
            paths.runtimeDirectoryURL,
            paths.computerUseDirectoryURL,
            paths.stateDirectoryURL.deletingLastPathComponent().deletingLastPathComponent(),
            paths.stateDirectoryURL.deletingLastPathComponent(),
            paths.stateDirectoryURL,
        ]
        guard privateDirectories.allSatisfy(Self.ensurePrivateDirectory) else { return false }
        return Self.writeAuthenticationToken(paths.authenticationToken, to: paths.authenticationTokenFileURL)
    }

    /// Synchronously prevents relaunch and stops the out-of-process helper.
    /// App termination cannot rely on an unstructured async task surviving exit.
    func stopForTermination() {
        desiredEnabled = false
        acceptsNewLaunches = false
        permissionRefreshGeneration &+= 1
        for cancel in helperLifecycleCancellationActions.values {
            cancel()
        }
        helperLifecycleCancellationActions.removeAll()
        helperLifecycleTask?.cancel()
        helperLifecycleTask = nil
        helperLifecycleGeneration &+= 1
        helperTerminationObservationTask?.cancel()
        helperTerminationObservationTask = nil
        helperHealthTask?.cancel()
        helperHealthTask = nil
        missedHelperHealthChecks = 0
        recoveryTask?.cancel()
        recoveryTask = nil
        _ = Self.sendDaemonRequestSynchronously(
            ["method": "shutdown"],
            paths: paths,
            transport: transport,
            timeout: 0.25
        )
        terminateRunningHelper(at: installedHelperURL ?? paths.installedHelperAppURL)
        clearTrackedHelperProcess()
        try? FileManager.default.removeItem(at: paths.daemonSocketURL)
        cachedStatus = .unknown
    }

    @discardableResult
    private func terminateRunningHelper(at helperURL: URL) -> Set<pid_t> {
        let applicationsByPID = runningHelperApplications(at: helperURL)
        var processIdentifiers = Set(applicationsByPID.keys)
        if let identity = runningHelperProcessIdentity,
           AgentPIDProcessIdentity(pid: identity.pid) == identity {
            processIdentifiers.insert(identity.pid)
            expectedTerminationProcessIdentifiers.insert(identity.pid)
            if applicationsByPID[identity.pid] == nil {
                _ = Darwin.kill(identity.pid, SIGKILL)
            }
        }
        for application in applicationsByPID.values {
            let pid = application.processIdentifier
            expectedTerminationProcessIdentifiers.insert(pid)
            guard !application.forceTerminate() else { continue }
            if Darwin.kill(pid, SIGKILL) != 0, errno != ESRCH {
                continue
            }
        }
        return processIdentifiers
    }

    private func runningHelperApplications(
        at helperURL: URL
    ) -> [pid_t: NSRunningApplication] {
        let expectedURL = helperURL.standardizedFileURL
        var applicationsByPID: [pid_t: NSRunningApplication] = [:]
        if let runningHelperProcessIdentifier,
           let application = NSRunningApplication(
               processIdentifier: runningHelperProcessIdentifier
           ),
           application.bundleURL?.standardizedFileURL == expectedURL {
            applicationsByPID[runningHelperProcessIdentifier] = application
        }
        if let bundleIdentifier = Bundle(url: helperURL)?.bundleIdentifier {
            for application in NSRunningApplication.runningApplications(
                withBundleIdentifier: bundleIdentifier
            ) where application.bundleURL?.standardizedFileURL == expectedURL {
                applicationsByPID[application.processIdentifier] = application
            }
        }
        return applicationsByPID
    }

    private func terminateRunningHelperAndWait(at helperURL: URL) async -> Bool {
        let processIdentifiers = terminateRunningHelper(at: helperURL)
        guard !processIdentifiers.isEmpty else { return true }
        if await waitForHelperProcessesToExit(
            processIdentifiers,
            helperURL: helperURL,
            attempts: 10
        ) {
            return true
        }

        // `forceTerminate()` reports whether AppKit accepted the request, not
        // whether the process actually exited. Revalidate each pid's exact
        // tracked generation or bundle URL before escalating so pid reuse
        // cannot kill an unrelated application.
        let expectedURL = helperURL.standardizedFileURL
        var signalSucceeded = true
        for pid in processIdentifiers {
            if let identity = runningHelperProcessIdentity,
               identity.pid == pid,
               AgentPIDProcessIdentity(pid: pid) == identity {
                if Darwin.kill(pid, SIGKILL) != 0, errno != ESRCH {
                    signalSucceeded = false
                }
                continue
            }
            guard
                let application = NSRunningApplication(processIdentifier: pid),
                application.bundleURL?.standardizedFileURL == expectedURL
            else {
                continue
            }
            if Darwin.kill(pid, SIGKILL) != 0, errno != ESRCH {
                signalSucceeded = false
            }
        }
        guard signalSucceeded else { return false }
        return await waitForHelperProcessesToExit(
            processIdentifiers,
            helperURL: helperURL,
            attempts: 20
        )
    }

    private func waitForHelperProcessesToExit(
        _ processIdentifiers: Set<pid_t>,
        helperURL: URL,
        attempts: Int
    ) async -> Bool {
        let expectedURL = helperURL.standardizedFileURL
        let clock = ContinuousClock()
        for attempt in 0 ... attempts {
            let stillRunning = processIdentifiers.contains { pid in
                if let identity = runningHelperProcessIdentity,
                   identity.pid == pid,
                   AgentPIDProcessIdentity(pid: pid) == identity {
                    return true
                }
                guard let application = NSRunningApplication(processIdentifier: pid) else {
                    return false
                }
                return application.bundleURL?.standardizedFileURL == expectedURL
                    && !application.isTerminated
            }
            if !stillRunning { return true }
            guard attempt < attempts, !Task.isCancelled else { return false }
            do {
                try await clock.sleep(for: .milliseconds(50))
            } catch {
                return false
            }
        }
        return false
    }

    private func clearTrackedHelperProcess() {
        runningHelperProcessIdentifier = nil
        runningHelperProcessIdentity = nil
    }

    private func recordExpectedTerminationOfRunningHelper(at helperURL: URL) {
        if let runningHelperProcessIdentifier {
            expectedTerminationProcessIdentifiers.insert(runningHelperProcessIdentifier)
        }
        let expectedURL = helperURL.standardizedFileURL
        guard let bundleIdentifier = Bundle(url: helperURL)?.bundleIdentifier else { return }
        for application in NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
        ) where application.bundleURL?.standardizedFileURL == expectedURL {
            expectedTerminationProcessIdentifiers.insert(application.processIdentifier)
        }
    }

    private func startObservingHelperTermination() {
        helperTerminationObservationTask = Task { @MainActor [weak self] in
            for await notification in NSWorkspace.shared.notificationCenter.notifications(
                named: NSWorkspace.didTerminateApplicationNotification
            ) {
                guard !Task.isCancelled else { return }
                guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication
                else {
                    continue
                }
                self?.helperDidTerminate(application)
            }
        }
    }

    private func helperDidTerminate(_ application: NSRunningApplication) {
        let isTrackedHelperProcess = application.processIdentifier == runningHelperProcessIdentifier
        if isTrackedHelperProcess {
            clearTrackedHelperProcess()
        }
        let wasExpected = expectedTerminationProcessIdentifiers.remove(
            application.processIdentifier
        ) != nil
        let helperURL = installedHelperURL ?? paths.installedHelperAppURL
        guard Self.shouldRecoverAfterHelperTermination(
            desiredEnabled: desiredEnabled,
            acceptsNewLaunches: acceptsNewLaunches,
            wasExpected: wasExpected,
            isTrackedHelperProcess: isTrackedHelperProcess,
            terminatedBundleIdentifier: application.bundleIdentifier,
            terminatedBundleURL: application.bundleURL,
            helperBundleIdentifier: Bundle(url: helperURL)?.bundleIdentifier,
            helperBundleURL: helperURL
        ) else {
            return
        }
        scheduleHelperRecovery()
    }

    private func startMonitoringHelperHealth() {
        guard desiredEnabled, acceptsNewLaunches, helperHealthTask == nil else { return }
        helperHealthTask = Task { @MainActor [weak self] in
            let clock = ContinuousClock()
            while !Task.isCancelled {
                do {
                    try await clock.sleep(for: .seconds(2))
                } catch {
                    return
                }
                guard let self else { return }
                await self.checkHelperHealth()
            }
        }
    }

    private func checkHelperHealth() async {
        let daemonListening = await Self.isDaemonListening(paths: paths, transport: transport)
        guard !Task.isCancelled else { return }
        if daemonListening {
            missedHelperHealthChecks = 0
            return
        }

        missedHelperHealthChecks += 1
        guard missedHelperHealthChecks >= 2 else { return }
        missedHelperHealthChecks = 0
        guard Self.shouldScheduleHelperRecovery(
            desiredEnabled: desiredEnabled,
            acceptsNewLaunches: acceptsNewLaunches,
            daemonListening: daemonListening,
            recoveryInFlight: recoveryTask != nil
        ) else {
            return
        }
        scheduleHelperRecovery()
    }

    private func scheduleHelperRecovery() {
        guard recoveryTask == nil else { return }
        recoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.startIfNeeded()
            self.recoveryTask = nil
        }
    }

    nonisolated static func shouldRecoverAfterHelperTermination(
        desiredEnabled: Bool,
        acceptsNewLaunches: Bool,
        wasExpected: Bool,
        isTrackedHelperProcess: Bool = false,
        terminatedBundleIdentifier: String?,
        terminatedBundleURL: URL?,
        helperBundleIdentifier: String?,
        helperBundleURL: URL
    ) -> Bool {
        guard desiredEnabled, acceptsNewLaunches, !wasExpected else { return false }
        if isTrackedHelperProcess { return true }
        guard let terminatedBundleIdentifier, let helperBundleIdentifier,
              terminatedBundleIdentifier == helperBundleIdentifier
        else {
            return false
        }
        return terminatedBundleURL?.standardizedFileURL == helperBundleURL.standardizedFileURL
    }

    nonisolated static func shouldScheduleHelperRecovery(
        desiredEnabled: Bool,
        acceptsNewLaunches: Bool,
        daemonListening: Bool,
        recoveryInFlight: Bool
    ) -> Bool {
        desiredEnabled
            && acceptsNewLaunches
            && !daemonListening
            && !recoveryInFlight
    }

    nonisolated private static func ensurePrivateDirectory(_ directoryURL: URL) -> Bool {
        let path = directoryURL.path
        var metadata = stat()
        if Darwin.lstat(path, &metadata) != 0 {
            guard errno == ENOENT, Darwin.mkdir(path, mode_t(0o700)) == 0 else { return false }
        }

        guard Darwin.lstat(path, &metadata) == 0,
              (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              metadata.st_uid == geteuid(),
              Darwin.chmod(path, mode_t(0o700)) == 0,
              Darwin.lstat(path, &metadata) == 0,
              (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              metadata.st_uid == geteuid(),
              (metadata.st_mode & mode_t(0o777)) == mode_t(0o700)
        else {
            return false
        }
        return true
    }

    nonisolated private static func writeAuthenticationToken(_ token: String, to fileURL: URL) -> Bool {
        let descriptor = Darwin.open(
            fileURL.path,
            O_WRONLY | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600)
        )
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }

        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              metadata.st_uid == geteuid(),
              metadata.st_nlink == 1,
              Darwin.fchmod(descriptor, mode_t(0o600)) == 0,
              Darwin.ftruncate(descriptor, 0) == 0,
              Darwin.lseek(descriptor, 0, SEEK_SET) == 0
        else {
            return false
        }

        let bytes = Array((token + "\n").utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { buffer -> Int in
                guard let baseAddress = buffer.baseAddress else { return -1 }
                return Darwin.write(descriptor, baseAddress.advanced(by: offset), bytes.count - offset)
            }
            if written < 0, errno == EINTR { continue }
            guard written > 0 else { return false }
            offset += written
        }
        guard Darwin.fsync(descriptor) == 0,
              Darwin.fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & mode_t(0o777)) == mode_t(0o600)
        else {
            return false
        }
        return true
    }

    private func openSystemSettings(_ deepLink: String) async -> Bool {
        guard let url = URL(string: deepLink) else { return false }
        guard let systemSettingsURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: Self.systemSettingsBundleIdentifier
        ) else {
            return NSWorkspace.shared.open(url)
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        return await withCheckedContinuation { continuation in
            NSWorkspace.shared.open(
                [url],
                withApplicationAt: systemSettingsURL,
                configuration: configuration,
                completionHandler: Self.makeWorkspaceOpenCompletion(
                    continuation: continuation
                )
            )
        }
    }

    /// LaunchServices invokes this completion on a concurrent queue. Construct
    /// it outside `MainActor` so Swift 6 does not install an actor-isolation
    /// precondition before the continuation can be resumed.
    nonisolated private static func makeHelperLaunchCompletion(
        continuation: CheckedContinuation<pid_t?, Never>
    ) -> @Sendable (NSRunningApplication?, Error?) -> Void {
        { application, error in
            continuation.resume(
                returning: error == nil ? application?.processIdentifier : nil
            )
        }
    }

    /// LaunchServices invokes this completion on a concurrent queue.
    nonisolated private static func makeWorkspaceOpenCompletion(
        continuation: CheckedContinuation<Bool, Never>
    ) -> @Sendable (NSRunningApplication?, Error?) -> Void {
        { application, error in
            continuation.resume(returning: application != nil && error == nil)
        }
    }

    nonisolated private static func helperIsCurrent(nested: URL, destination: URL) -> Bool {
        guard !Task.isCancelled else { return false }
        let fileManager = FileManager.default
        let nestedBinary = nested.appendingPathComponent("Contents/MacOS/cmux-cua-driver")
        let destinationBinary = destination.appendingPathComponent("Contents/MacOS/cmux-cua-driver")
        guard fileManager.isExecutableFile(atPath: destinationBinary.path) else { return false }
        guard fileManager.contentsEqual(
            atPath: nested.appendingPathComponent("Contents/Info.plist").path,
            andPath: destination.appendingPathComponent("Contents/Info.plist").path
        ), !Task.isCancelled else {
            return false
        }
        return fileManager.contentsEqual(
            atPath: nestedBinary.path,
            andPath: destinationBinary.path
        )
    }

    nonisolated private static func installHelper(
        nested: URL,
        destination: URL,
        directory: URL
    ) -> URL? {
        let fileManager = FileManager.default
        do {
            guard !Task.isCancelled else { return nil }
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let temporary = directory.appendingPathComponent(
                ".cmux Computer Use.\(UUID().uuidString).app",
                isDirectory: true
            )
            try? fileManager.removeItem(at: temporary)
            defer { try? fileManager.removeItem(at: temporary) }
            try fileManager.copyItem(at: nested, to: temporary)
            guard !Task.isCancelled else { return nil }
            try? fileManager.removeItem(at: destination)
            try fileManager.moveItem(at: temporary, to: destination)
            return destination
        } catch {
            return nil
        }
    }

    nonisolated private static func makeStateAuthenticationKey() -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            == errSecSuccess
        {
            return Data(bytes)
        }
        var generator = SystemRandomNumberGenerator()
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: .min ... .max, using: &generator)
        }
        return Data(bytes)
    }

    nonisolated private static func isDaemonListening(
        paths: ComputerUseRuntimePaths,
        transport: SocketTransport
    ) async -> Bool {
        await sendDaemonRequest(
            ["method": "list"],
            paths: paths,
            transport: transport,
            timeout: 1
        )?["ok"] as? Bool == true
    }

    nonisolated private static func queryPermissionStatus(
        paths: ComputerUseRuntimePaths,
        transport: SocketTransport
    ) async -> ComputerUsePermissionStatus? {
        guard
            let response = await sendDaemonRequest(
                [
                    "method": "call",
                    "name": "check_permissions",
                    "args": ["prompt": false],
                ],
                paths: paths,
                transport: transport,
                timeout: 2
            ),
            response["ok"] as? Bool == true,
            let result = response["result"] as? [String: Any],
            let structured = result["structuredContent"] as? [String: Any]
        else {
            return nil
        }
        return ComputerUsePermissionStatus(structuredContent: structured)
    }

    nonisolated private static func sendDaemonRequest(
        _ request: [String: Any],
        paths: ComputerUseRuntimePaths,
        transport: SocketTransport,
        timeout: TimeInterval,
        expectedPeerIdentity: AgentPIDProcessIdentity? = nil
    ) async -> [String: Any]? {
        await Task.detached(priority: .userInitiated) {
            sendDaemonRequestSynchronously(
                request,
                paths: paths,
                transport: transport,
                timeout: timeout,
                expectedPeerIdentity: expectedPeerIdentity
            )
        }.value
    }

    nonisolated private static func sendDaemonRequestSynchronously(
        _ request: [String: Any],
        paths: ComputerUseRuntimePaths,
        transport: SocketTransport,
        timeout: TimeInterval,
        expectedPeerIdentity: AgentPIDProcessIdentity? = nil
    ) -> [String: Any]? {
        let authenticatedRequest: [String: Any] = [
            "auth_token": paths.authenticationToken,
            "request": request,
        ]
        guard
            JSONSerialization.isValidJSONObject(authenticatedRequest),
            let data = try? JSONSerialization.data(withJSONObject: authenticatedRequest),
            let line = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        let socketPath = paths.daemonSocketURL.path
        guard
            let probe = transport.probeCommandWithPeerProcessID(
                line,
                at: socketPath,
                timeout: timeout,
                validatingPeer: { peerProcessID in
                    expectedPeerIdentity.map { expected in
                        guard
                            peerProcessID == expected.pid,
                            let current = AgentPIDProcessIdentity(
                                pid: expected.pid
                            )
                        else {
                            return false
                        }
                        return current == expected
                    } ?? true
                }
            ),
            let data = probe.response.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return object
    }

    nonisolated private static func waitForPermissionStatus(
        paths: ComputerUseRuntimePaths,
        transport: SocketTransport
    ) async -> ComputerUsePermissionStatus? {
        if let status = await queryPermissionStatus(paths: paths, transport: transport) {
            return status
        }
        let events = directoryEvents(at: paths.runtimeDirectoryURL)
        if let status = await queryPermissionStatus(paths: paths, transport: transport) {
            return status
        }
        return await withTaskGroup(of: ComputerUsePermissionStatus?.self) { group in
            group.addTask {
                for await _ in events {
                    guard !Task.isCancelled else { return nil }
                    if let status = await queryPermissionStatus(paths: paths, transport: transport) {
                        return status
                    }
                }
                return nil
            }
            group.addTask {
                // Genuine upper deadline; readiness itself is driven by directory events.
                try? await ContinuousClock().sleep(for: .seconds(5))
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    nonisolated private static func waitForDaemonStart(
        paths: ComputerUseRuntimePaths,
        transport: SocketTransport
    ) async -> Bool {
        if await isDaemonListening(paths: paths, transport: transport) { return true }
        let events = directoryEvents(at: paths.runtimeDirectoryURL)
        if await isDaemonListening(paths: paths, transport: transport) { return true }
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in events {
                    guard !Task.isCancelled else { return false }
                    if await isDaemonListening(paths: paths, transport: transport) {
                        return true
                    }
                }
                return false
            }
            group.addTask {
                // Genuine upper deadline; readiness itself is driven by UDS lifecycle events.
                try? await ContinuousClock().sleep(for: .seconds(5))
                return false
            }
            let started = await group.next() ?? false
            group.cancelAll()
            return started
        }
    }

    nonisolated private static func waitForDaemonStop(
        paths: ComputerUseRuntimePaths,
        transport: SocketTransport
    ) async -> Bool {
        guard await isDaemonListening(paths: paths, transport: transport) else { return true }
        let events = directoryEvents(at: paths.runtimeDirectoryURL)
        guard await isDaemonListening(paths: paths, transport: transport) else { return true }
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in events {
                    guard !Task.isCancelled else { return false }
                    if !(await isDaemonListening(paths: paths, transport: transport)) {
                        return true
                    }
                }
                return false
            }
            group.addTask {
                // Genuine upper deadline; shutdown itself is driven by the UDS lifecycle event.
                try? await ContinuousClock().sleep(for: .seconds(3))
                return false
            }
            let stopped = await group.next() ?? false
            group.cancelAll()
            return stopped
        }
    }

    nonisolated private static func directoryEvents(at directoryURL: URL) -> AsyncStream<Void> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let descriptor = Darwin.open(directoryURL.path, O_EVTONLY)
            guard descriptor >= 0 else {
                continuation.finish()
                return
            }
            // DispatchSource is the system's only event-driven directory watcher.
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .extend, .attrib, .link, .delete, .rename],
                queue: .global(qos: .userInitiated)
            )
            source.setEventHandler {
                continuation.yield()
            }
            source.setCancelHandler {
                Darwin.close(descriptor)
                continuation.finish()
            }
            continuation.onTermination = { _ in
                source.cancel()
            }
            source.resume()
        }
    }

    nonisolated private static func mergedFileSystemEvents(
        at urls: [URL],
        fallbackInterval: Duration
    ) -> AsyncStream<Void> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let observationTask = Task.detached(priority: .utility) {
                await withTaskGroup(of: Void.self) { group in
                    for url in urls {
                        group.addTask {
                            for await _ in directoryEvents(at: url) {
                                guard !Task.isCancelled else { return }
                                continuation.yield()
                            }
                        }
                    }
                    group.addTask {
                        let clock = ContinuousClock()
                        while !Task.isCancelled {
                            do {
                                try await clock.sleep(for: fallbackInterval)
                            } catch {
                                return
                            }
                            guard !Task.isCancelled else { return }
                            // Some macOS releases deny or coalesce filesystem
                            // observation of the user's TCC database. Keep one
                            // bounded passive status probe as a fallback so a
                            // real toggle is still observed promptly.
                            continuation.yield()
                        }
                    }
                    await group.waitForAll()
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                observationTask.cancel()
            }
        }
    }
}
