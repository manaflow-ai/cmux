import AppKit
import CmuxControlSocket
import Darwin
import Foundation

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

    private let bundledHelperAppURL: URL?
    private let transport: SocketTransport
    private var installedHelperURL: URL?
    private var installationTask: Task<URL?, Never>?
    private var helperTerminationObservationTask: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?
    private var cachedStatus = ComputerUsePermissionStatus.missing
    private var acceptsNewLaunches = true
    private var desiredEnabled = false
    private var expectedTerminationProcessIdentifiers: Set<pid_t> = []

    init(
        bundle: Bundle = .main,
        paths: ComputerUseRuntimePaths = ComputerUseRuntimePaths(),
        transport: SocketTransport = SocketTransport()
    ) {
        self.paths = paths
        self.transport = transport
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
        helperTerminationObservationTask?.cancel()
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

    /// Reconciles the helper daemon with the live `computerUse.enabled` setting.
    func setEnabled(_ newValue: Bool) async {
        guard acceptsNewLaunches, !Task.isCancelled else { return }
        desiredEnabled = newValue
        if newValue {
            await startIfNeeded()
        } else {
            recoveryTask?.cancel()
            recoveryTask = nil
            await stopDaemon()
            try? FileManager.default.removeItem(at: paths.authenticationTokenFileURL)
            cachedStatus = .missing
        }
    }

    /// Installs the nested helper at its independently registered top-level URL.
    @discardableResult
    func ensureStandaloneHelperInstalled() async -> URL? {
        guard acceptsNewLaunches, !Task.isCancelled, prepareRuntimeForLaunch() else { return nil }
        if let installationTask {
            let result = await installationTask.value
            guard acceptsNewLaunches, !Task.isCancelled else { return nil }
            installedHelperURL = result
            return result
        }
        guard let bundledHelperAppURL else { return nil }

        let destination = paths.installedHelperAppURL
        let isCurrent = await Task.detached(priority: .userInitiated) {
            Self.helperIsCurrent(nested: bundledHelperAppURL, destination: destination)
        }.value
        guard acceptsNewLaunches, !Task.isCancelled else { return nil }
        if isCurrent {
            installedHelperURL = destination
            return destination
        }

        await stopDaemon()
        guard acceptsNewLaunches, !Task.isCancelled else { return nil }
        recoverStaleDaemonIfNeeded(helperURL: destination)
        let directory = paths.installedHelperDirectoryURL
        let task = Task.detached(priority: .userInitiated) {
            Self.installHelper(
                nested: bundledHelperAppURL,
                destination: destination,
                directory: directory
            )
        }
        installationTask = task
        let result = await task.value
        installationTask = nil
        guard acceptsNewLaunches, !Task.isCancelled else { return nil }
        installedHelperURL = result
        return result
    }

    /// Restarts only the helper, then reads its fresh TCC status over the UDS.
    @discardableResult
    func refreshHelperStatus() async -> (accessibility: Bool, screenRecording: Bool) {
        guard let helperURL = await ensureStandaloneHelperInstalled() else {
            cachedStatus = .missing
            return status()
        }

        await stopDaemon()
        guard await launchHelper(at: helperURL) else {
            cachedStatus = .missing
            return status()
        }
        cachedStatus = await Self.waitForPermissionStatus(
            paths: paths,
            transport: transport
        ) ?? .missing
        return status()
    }

    func requestAccessibility() async -> Bool {
        await requestSystemPermission(named: "accessibility")
    }

    func requestScreenRecording() async -> Bool {
        await requestSystemPermission(named: "screen_recording")
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

    private func startIfNeeded() async {
        guard acceptsNewLaunches, !Task.isCancelled else { return }
        guard let helperURL = await ensureStandaloneHelperInstalled() else { return }
        guard acceptsNewLaunches, !Task.isCancelled else { return }
        guard !(await Self.isDaemonListening(paths: paths, transport: transport)) else { return }
        guard acceptsNewLaunches, !Task.isCancelled else { return }
        recoverStaleDaemonIfNeeded(helperURL: helperURL)
        guard await launchHelper(at: helperURL) else { return }
        guard acceptsNewLaunches, !Task.isCancelled else { return }
        _ = await Self.waitForDaemonStart(paths: paths, transport: transport)
    }

    /// Asks the independently attributed helper to raise one native TCC request.
    ///
    /// This host-only daemon method is separate from the MCP tool registry, so an
    /// agent cannot bypass onboarding with `check_permissions { prompt: true }`.
    private func requestSystemPermission(named name: String) async -> Bool {
        guard acceptsNewLaunches, !Task.isCancelled else { return false }
        await startIfNeeded()
        guard acceptsNewLaunches, !Task.isCancelled else { return false }
        return await Self.sendDaemonRequest(
            [
                "method": "request_system_permission",
                "name": name,
            ],
            paths: paths,
            transport: transport,
            timeout: 5
        )?["ok"] as? Bool == true
    }

    private func stopDaemon() async {
        guard await Self.isDaemonListening(paths: paths, transport: transport) else { return }
        recordExpectedTerminationOfRunningHelper(at: installedHelperURL ?? paths.installedHelperAppURL)
        _ = await Self.sendDaemonRequest(
            ["method": "shutdown"],
            paths: paths,
            transport: transport,
            timeout: 2
        )
        _ = await Self.waitForDaemonStop(paths: paths, transport: transport)
    }

    private func launchHelper(at helperURL: URL) async -> Bool {
        guard acceptsNewLaunches, !Task.isCancelled, prepareRuntimeForLaunch() else { return false }
        let launch = ComputerUseHelperLaunchConfiguration(paths: paths)

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.createsNewApplicationInstance = true
        configuration.arguments = launch.arguments
        configuration.environment = launch.environment
        let launched = await withCheckedContinuation { continuation in
            NSWorkspace.shared.openApplication(
                at: helperURL,
                configuration: configuration
            ) { _, error in
                continuation.resume(returning: error == nil)
            }
        }
        guard launched, acceptsNewLaunches, !Task.isCancelled else {
            terminateRunningHelper(at: helperURL)
            return false
        }
        return true
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
        installationTask?.cancel()
        installationTask = nil
        helperTerminationObservationTask?.cancel()
        helperTerminationObservationTask = nil
        recoveryTask?.cancel()
        recoveryTask = nil
        _ = Self.sendDaemonRequestSynchronously(
            ["method": "shutdown"],
            paths: paths,
            transport: transport,
            timeout: 0.25
        )
        terminateRunningHelper(at: installedHelperURL ?? paths.installedHelperAppURL)
        try? FileManager.default.removeItem(at: paths.daemonSocketURL)
        try? FileManager.default.removeItem(at: paths.authenticationTokenFileURL)
        cachedStatus = .missing
    }

    /// Removes a helper left by an older app process whose per-launch socket
    /// credential no longer matches this process.
    private func recoverStaleDaemonIfNeeded(helperURL: URL) {
        guard FileManager.default.fileExists(atPath: paths.daemonSocketURL.path) else { return }
        terminateRunningHelper(at: helperURL)
        try? FileManager.default.removeItem(at: paths.daemonSocketURL)
    }

    private func terminateRunningHelper(at helperURL: URL) {
        let expectedURL = helperURL.standardizedFileURL
        if let bundleIdentifier = Bundle(url: helperURL)?.bundleIdentifier {
            for application in NSRunningApplication.runningApplications(
                withBundleIdentifier: bundleIdentifier
            ) where application.bundleURL?.standardizedFileURL == expectedURL {
                expectedTerminationProcessIdentifiers.insert(application.processIdentifier)
                _ = application.forceTerminate()
            }
        }
    }

    private func recordExpectedTerminationOfRunningHelper(at helperURL: URL) {
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
        let wasExpected = expectedTerminationProcessIdentifiers.remove(
            application.processIdentifier
        ) != nil
        let helperURL = installedHelperURL ?? paths.installedHelperAppURL
        guard Self.shouldRecoverAfterHelperTermination(
            desiredEnabled: desiredEnabled,
            acceptsNewLaunches: acceptsNewLaunches,
            wasExpected: wasExpected,
            terminatedBundleIdentifier: application.bundleIdentifier,
            terminatedBundleURL: application.bundleURL,
            helperBundleIdentifier: Bundle(url: helperURL)?.bundleIdentifier,
            helperBundleURL: helperURL
        ) else {
            return
        }
        guard recoveryTask == nil else { return }
        recoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await startIfNeeded()
            recoveryTask = nil
        }
    }

    static func shouldRecoverAfterHelperTermination(
        desiredEnabled: Bool,
        acceptsNewLaunches: Bool,
        wasExpected: Bool,
        terminatedBundleIdentifier: String?,
        terminatedBundleURL: URL?,
        helperBundleIdentifier: String?,
        helperBundleURL: URL
    ) -> Bool {
        guard desiredEnabled, acceptsNewLaunches, !wasExpected else { return false }
        guard let terminatedBundleIdentifier, let helperBundleIdentifier,
              terminatedBundleIdentifier == helperBundleIdentifier
        else {
            return false
        }
        return terminatedBundleURL?.standardizedFileURL == helperBundleURL.standardizedFileURL
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
                configuration: configuration
            ) { application, error in
                continuation.resume(returning: application != nil && error == nil)
            }
        }
    }

    nonisolated private static func helperIsCurrent(nested: URL, destination: URL) -> Bool {
        let fileManager = FileManager.default
        let nestedBinary = nested.appendingPathComponent("Contents/MacOS/cmux-cua-driver")
        let destinationBinary = destination.appendingPathComponent("Contents/MacOS/cmux-cua-driver")
        guard fileManager.isExecutableFile(atPath: destinationBinary.path) else { return false }
        guard fileManager.contentsEqual(
            atPath: nested.appendingPathComponent("Contents/Info.plist").path,
            andPath: destination.appendingPathComponent("Contents/Info.plist").path
        ) else {
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
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let temporary = directory.appendingPathComponent(
                ".cmux Computer Use.\(UUID().uuidString).app",
                isDirectory: true
            )
            try? fileManager.removeItem(at: temporary)
            try fileManager.copyItem(at: nested, to: temporary)
            try? fileManager.removeItem(at: destination)
            try fileManager.moveItem(at: temporary, to: destination)
            return destination
        } catch {
            return nil
        }
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
        return ComputerUsePermissionStatus(
            accessibility: structured["accessibility"] as? Bool ?? false,
            screenRecording: structured["screen_recording"] as? Bool ?? false
        )
    }

    nonisolated private static func sendDaemonRequest(
        _ request: [String: Any],
        paths: ComputerUseRuntimePaths,
        transport: SocketTransport,
        timeout: TimeInterval
    ) async -> [String: Any]? {
        await Task.detached(priority: .userInitiated) {
            sendDaemonRequestSynchronously(
                request,
                paths: paths,
                transport: transport,
                timeout: timeout
            )
        }.value
    }

    nonisolated private static func sendDaemonRequestSynchronously(
        _ request: [String: Any],
        paths: ComputerUseRuntimePaths,
        transport: SocketTransport,
        timeout: TimeInterval
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
            let response = transport.probeCommand(line, at: socketPath, timeout: timeout),
            let data = response.data(using: .utf8),
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
        AsyncStream { continuation in
            let descriptor = Darwin.open(directoryURL.path, O_EVTONLY)
            guard descriptor >= 0 else {
                continuation.finish()
                return
            }
            // DispatchSource is the system's only event-driven directory watcher.
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .delete, .rename],
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
}
