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

    let paths: ComputerUseRuntimePaths
    let applicationName: String

    private let bundledHelperAppURL: URL?
    private let helperBundleIdentifier: String?
    private let transport: SocketTransport
    private var installedHelperURL: URL?
    private var installationTask: Task<URL?, Never>?
    private var cachedStatus = ComputerUsePermissionStatus.missing
    private var helperTerminationTask: Task<Void, Never>?
    private var monitoredHelperProcessIdentifier: pid_t?
    private lazy var helperSupervisor = ComputerUseHelperSupervisor(
        helperAppURL: paths.installedHelperAppURL,
        helperBundleIdentifier: helperBundleIdentifier
    ) { [weak self] in
        guard let self else { return }
        await self.startIfNeeded()
    }

    init(
        bundle: Bundle = .main,
        paths: ComputerUseRuntimePaths = ComputerUseRuntimePaths(),
        transport: SocketTransport = SocketTransport()
    ) {
        self.paths = paths
        self.transport = transport
        let nestedURL = bundle.bundleURL
            .appendingPathComponent("Contents/Library/\(Self.helperAppName).app", isDirectory: true)
        if FileManager.default.fileExists(atPath: nestedURL.path) {
            bundledHelperAppURL = nestedURL
            helperBundleIdentifier = Bundle(url: nestedURL)?.bundleIdentifier
            applicationName = Self.displayName(for: nestedURL)
        } else {
            bundledHelperAppURL = nil
            helperBundleIdentifier = nil
            applicationName = Self.helperAppName
        }
    }

    var helperAppURL: URL? {
        installedHelperURL
    }

    var stateDirectoryURL: URL {
        paths.stateDirectoryURL
    }

    func status() -> (accessibility: Bool, screenRecording: Bool) {
        (cachedStatus.accessibility, cachedStatus.screenRecording)
    }

    /// Reconciles the helper daemon with the live `computerUse.enabled` setting.
    func setEnabled(_ newValue: Bool) async {
        helperSupervisor.setEnabled(newValue)
        if newValue {
            await startIfNeeded()
        } else {
            await stopDaemon()
            cachedStatus = .missing
        }
    }

    /// Installs the nested helper at its independently registered top-level URL.
    @discardableResult
    func ensureStandaloneHelperInstalled() async -> URL? {
        if let installationTask {
            return await installationTask.value
        }
        guard let bundledHelperAppURL else { return nil }

        let destination = paths.installedHelperAppURL
        let isCurrent = await Task.detached(priority: .userInitiated) {
            Self.helperIsCurrent(nested: bundledHelperAppURL, destination: destination)
        }.value
        if isCurrent {
            installedHelperURL = destination
            return destination
        }

        await stopDaemon()
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
        await launchHelper(at: helperURL)
        cachedStatus = await Self.waitForPermissionStatus(
            paths: paths,
            transport: transport
        ) ?? .missing
        if let application = Self.runningHelperApplication(at: helperURL) {
            await monitorHelper(application)
        }
        return status()
    }

    func requestAccessibility() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await ensureStandaloneHelperInstalled()
            openAccessibilitySettings()
        }
    }

    func requestScreenRecording() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await ensureStandaloneHelperInstalled()
            openScreenRecordingSettings()
        }
    }

    func revealHelperInFinder() {
        Task { @MainActor [weak self] in
            guard let self, let url = await ensureStandaloneHelperInstalled() else { return }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    func openAccessibilitySettings() {
        openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    func openScreenRecordingSettings() {
        openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    private func startIfNeeded() async {
        guard let helperURL = await ensureStandaloneHelperInstalled() else { return }
        if await Self.isDaemonListening(paths: paths, transport: transport) {
            if let application = Self.runningHelperApplication(at: helperURL) {
                await monitorHelper(application)
                return
            }

            // A listening daemon without the exact LaunchServices app instance
            // is not lifecycle-owned by cmux. Replace it with a monitored helper.
            await stopDaemon()
        }
        await launchHelper(at: helperURL)
        guard await Self.waitForDaemonStart(paths: paths, transport: transport) else { return }
        if let application = Self.runningHelperApplication(at: helperURL) {
            await monitorHelper(application)
        }
    }

    private func stopDaemon() async {
        cancelHelperMonitoring()
        guard await Self.isDaemonListening(paths: paths, transport: transport) else { return }
        _ = await Self.sendDaemonRequest(
            ["method": "shutdown"],
            socketURL: paths.daemonSocketURL,
            transport: transport,
            timeout: 2
        )
        _ = await Self.waitForDaemonStop(paths: paths, transport: transport)
    }

    private func launchHelper(at helperURL: URL) async {
        let launch = ComputerUseHelperLaunchConfiguration(paths: paths)
        try? FileManager.default.createDirectory(
            at: paths.runtimeDirectoryURL,
            withIntermediateDirectories: true
        )
        try? FileManager.default.createDirectory(
            at: paths.stateDirectoryURL,
            withIntermediateDirectories: true
        )

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.createsNewApplicationInstance = true
        configuration.arguments = launch.arguments
        configuration.environment = launch.environment
        let application = await withCheckedContinuation { continuation in
            NSWorkspace.shared.openApplication(
                at: helperURL,
                configuration: configuration
            ) { application, _ in
                continuation.resume(returning: application)
            }
        }
        guard let application else { return }
        await monitorHelper(application)
    }

    private func monitorHelper(_ application: NSRunningApplication) async {
        cancelHelperMonitoring()
        let processIdentifier = application.processIdentifier
        let bundleURL = application.bundleURL
        let bundleIdentifier = application.bundleIdentifier
        monitoredHelperProcessIdentifier = processIdentifier
        helperSupervisor.helperDidLaunch(
            bundleURL: bundleURL,
            bundleIdentifier: bundleIdentifier,
            processIdentifier: processIdentifier
        )

        let exitEvents = Self.processExitEvents(processIdentifier: processIdentifier)
        helperTerminationTask = Task { @MainActor [weak self] in
            for await exitedProcessIdentifier in exitEvents {
                guard !Task.isCancelled else { return }
                guard let self else { return }
                await monitoredHelperDidTerminate(
                    bundleURL: bundleURL,
                    bundleIdentifier: bundleIdentifier,
                    processIdentifier: exitedProcessIdentifier
                )
                return
            }
        }
        if application.isTerminated {
            await monitoredHelperDidTerminate(
                bundleURL: bundleURL,
                bundleIdentifier: bundleIdentifier,
                processIdentifier: processIdentifier
            )
        }
    }

    private func monitoredHelperDidTerminate(
        bundleURL: URL?,
        bundleIdentifier: String?,
        processIdentifier: pid_t
    ) async {
        guard monitoredHelperProcessIdentifier == processIdentifier else { return }
        cancelHelperMonitoring()
        await helperSupervisor.helperDidTerminate(
            bundleURL: bundleURL,
            bundleIdentifier: bundleIdentifier,
            processIdentifier: processIdentifier
        )
    }

    private func cancelHelperMonitoring() {
        helperTerminationTask?.cancel()
        helperTerminationTask = nil
        monitoredHelperProcessIdentifier = nil
    }

    private func openSystemSettings(_ deepLink: String) {
        guard let url = URL(string: deepLink) else { return }
        NSWorkspace.shared.open(url)
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

    nonisolated private static func displayName(for helperAppURL: URL) -> String {
        guard
            let bundle = Bundle(url: helperAppURL),
            let candidate = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
        else {
            return helperAppName
        }
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? helperAppName : trimmed
    }

    private static func runningHelperApplication(at helperAppURL: URL) -> NSRunningApplication? {
        guard let bundleIdentifier = Bundle(url: helperAppURL)?.bundleIdentifier else { return nil }
        let expectedURL = helperAppURL.resolvingSymlinksInPath().standardizedFileURL
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first { application in
            guard !application.isTerminated, let bundleURL = application.bundleURL else { return false }
            return bundleURL.resolvingSymlinksInPath().standardizedFileURL == expectedURL
        }
    }

    nonisolated private static func isDaemonListening(
        paths: ComputerUseRuntimePaths,
        transport: SocketTransport
    ) async -> Bool {
        await sendDaemonRequest(
            ["method": "list"],
            socketURL: paths.daemonSocketURL,
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
                socketURL: paths.daemonSocketURL,
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
        socketURL: URL,
        transport: SocketTransport,
        timeout: TimeInterval
    ) async -> [String: Any]? {
        guard
            JSONSerialization.isValidJSONObject(request),
            let data = try? JSONSerialization.data(withJSONObject: request),
            let line = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        let socketPath = socketURL.path
        return await Task.detached(priority: .userInitiated) {
            guard
                let response = transport.probeCommand(line, at: socketPath, timeout: timeout),
                let data = response.data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                return nil
            }
            return object
        }.value
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

    nonisolated static func processExitEvents(processIdentifier: pid_t) -> AsyncStream<pid_t> {
        AsyncStream { continuation in
            // DispatchSource is Darwin's event-driven process-exit primitive; callers see only an AsyncStream.
            let source = DispatchSource.makeProcessSource(
                identifier: processIdentifier,
                eventMask: .exit,
                queue: .global(qos: .userInitiated)
            )
            source.setEventHandler {
                continuation.yield(processIdentifier)
                continuation.finish()
            }
            source.setCancelHandler {
                continuation.finish()
            }
            continuation.onTermination = { _ in
                source.cancel()
            }
            source.resume()
        }
    }
}
