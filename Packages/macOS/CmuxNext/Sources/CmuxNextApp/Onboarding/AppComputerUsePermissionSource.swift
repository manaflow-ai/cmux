import AppKit
import CmuxNextAgentActivity
import CmuxNextOnboarding
import os

private let computerUseLogger = Logger(subsystem: "com.cmuxterm.app.next", category: "computer-use")

/// The computer use step's grants from the cmux-cua daemon:
/// `permissions_status` (AXIsProcessTrusted and
/// CGPreflightScreenCaptureAccess in the helper; read-only, never prompts),
/// asked once a second only while the step shows. The daemon has no push
/// for grants, and a second is as fast as anyone flips a switch.
@MainActor
final class AppComputerUsePermissionSource: ComputerUsePermissionSource {
    static let installedHelper = URL(fileURLWithPath: "/Applications/cmux Computer Use.app")
    private let configuration: AgentActivitySocketSource.Configuration
    private let identity: CuaHelperIdentity
    /// The Developer ID signed helper to drag into a list, or nil when this
    /// build has none (`CuaHelperIdentity`): then Allow reports computer use
    /// unavailable instead of offering an ad-hoc copy, whose grant would
    /// replace the release helper's TCC row.
    private(set) var helperAppURL: URL?
    /// The running daemon's app the last resolution was for (nil: none known yet).
    private var resolvedRunning: URL??

    init(configuration: AgentActivitySocketSource.Configuration, identity: CuaHelperIdentity = CuaHelperIdentity()) {
        self.configuration = configuration
        self.identity = identity
    }

    /// A source over the default socket, or nil when no cmux-cua daemon
    /// listens there (onboarding then leaves the step out). A socket file
    /// left by a daemon that exited does not count.
    static func local(_ configuration: AgentActivitySocketSource.Configuration
                      = .standard(machineName: "")) -> AppComputerUsePermissionSource? {
        guard isListening(configuration.socketPath) else { return nil }
        return AppComputerUsePermissionSource(configuration: configuration)
    }

    /// Whether a process accepts connections on the Unix socket at `path`.
    /// The descriptor is non-blocking, so a local connect returns at once:
    /// accepted, or refused (no daemon). EAGAIN, where a system reports a
    /// full backlog that way, still counts as listening.
    static func isListening(_ path: String) -> Bool {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else { return false }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8)
            buffer[path.utf8.count] = 0
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                // concurrency-allow: O_NONBLOCK local connect, answered at once and never waits on the daemon
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return result == 0 || errno == EAGAIN
    }

    func permissions() -> AsyncStream<ComputerUsePermissions> {
        let (stream, continuation) = AsyncStream<ComputerUsePermissions>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let task = Task { [weak self] in
            var last: ComputerUsePermissions?
            // wakeup-allow: one awaited socket read per second while the computer use step shows, ended by cancel when it goes
            while !Task.isCancelled {
                guard let self else { break }
                if let value = await read(), value != last {
                    last = value
                    continuation.yield(value)
                }
                // wakeup-allow: 1 s grant poll only while the computer use step shows (the daemon has no push for grants)
                try? await Task.sleep(for: .seconds(1))
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    func openSettings(_ pane: ComputerUsePermissionPane) {
        guard let url = Self.settingsURL(pane) else { return }
        NSWorkspace.shared.open(url)
    }

    static func settingsURL(_ pane: ComputerUsePermissionPane) -> URL? {
        let anchor = switch pane {
        case .accessibility: "Privacy_Accessibility"
        case .screenRecording: "Privacy_ScreenCapture"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
    }

    /// One `permissions_status`; nil when the daemon did not answer (the
    /// rows keep what they showed). A daemon that answers but refuses the
    /// request, or answers in another shape, runs a helper of another
    /// protocol version: that is reported (and logged), never silent.
    private func read() async -> ComputerUsePermissions? {
        let client = CuaSocketClient(configuration: configuration)
        let status: [String: Any]
        do {
            status = try await client.send("permissions_status", deadline: .seconds(2))
        } catch AgentActivitySourceError.refused(let reason) {
            computerUseLogger.error("cmux-cua refused permissions_status (\(reason, privacy: .public)): helper version mismatch")
            return .helperVersionMismatch
        } catch AgentActivitySourceError.malformed {
            computerUseLogger.error("cmux-cua answered permissions_status with a malformed reply: helper version mismatch")
            return .helperVersionMismatch
        } catch {
            return nil
        }
        guard status["accessibility"] is Bool, status["screen_recording"] is Bool else {
            computerUseLogger.error("cmux-cua permissions_status reply lacks the grants: helper version mismatch")
            return .helperVersionMismatch
        }
        var running: URL?
        if let pid = (status["source"] as? [String: Any])?["pid"] as? Int,
           let app = NSRunningApplication(processIdentifier: pid_t(pid))?.bundleURL, app.pathExtension == "app" {
            running = app
        }
        if resolvedRunning != .some(running) {
            resolvedRunning = .some(running)
            helperAppURL = await Self.resolve(identity, running: running, isDevBuild: ComputerUseHelperDaemon.isDevBuild).helperURL
        }
        return Self.permissions(status)
    }

    /// The signature checks read bundles on disk, so they run off the main
    /// actor, once per daemon app (not on every one-second read).
    @concurrent nonisolated static func resolve(_ identity: CuaHelperIdentity, running: URL?,
                                                isDevBuild: Bool) async -> CuaHelperIdentity.Resolution {
        identity.resolve(running: running, installed: CuaHelperIdentity.installedCandidates(isDevBuild: isDevBuild))
    }

    /// The two grants out of a `permissions_status` result.
    static func permissions(_ status: [String: Any]) -> ComputerUsePermissions {
        ComputerUsePermissions(accessibility: status["accessibility"] as? Bool ?? false,
                               screenRecording: status["screen_recording"] as? Bool ?? false)
    }
}
