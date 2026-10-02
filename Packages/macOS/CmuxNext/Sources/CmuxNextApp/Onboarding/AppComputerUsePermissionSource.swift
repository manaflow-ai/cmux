import AppKit
import CmuxNextAgentActivity
import CmuxNextOnboarding

/// The computer use step's grants from the cmux-cua daemon:
/// `permissions_status` (AXIsProcessTrusted and
/// CGPreflightScreenCaptureAccess in the helper; read-only, never prompts),
/// asked once a second only while the step shows. The daemon has no push
/// for grants, and a second is as fast as anyone flips a switch.
@MainActor
final class AppComputerUsePermissionSource: ComputerUsePermissionSource {
    static let installedHelper = URL(fileURLWithPath: "/Applications/cmux Computer Use.app")
    private let configuration: AgentActivitySocketSource.Configuration
    /// The installed helper until the daemon says which app it runs in.
    private(set) var helperAppURL = AppComputerUsePermissionSource.installedHelper

    init(configuration: AgentActivitySocketSource.Configuration) {
        self.configuration = configuration
    }

    /// A source over the default socket, or nil when no cmux-cua daemon
    /// listens there (onboarding then leaves the step out). A socket file
    /// left by a daemon that exited does not count.
    static func local() -> AppComputerUsePermissionSource? {
        let configuration = AgentActivitySocketSource.Configuration.standard(machineName: "")
        guard isListening(configuration.socketPath) else { return nil }
        return AppComputerUsePermissionSource(configuration: configuration)
    }

    /// Whether a process accepts connections on the Unix socket at `path`.
    /// The descriptor is non-blocking, so a local connect returns at once:
    /// accepted, refused (no daemon), or EAGAIN (a daemon with a full
    /// backlog, which still counts).
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
    /// rows keep what they showed).
    private func read() async -> ComputerUsePermissions? {
        guard let status = try? await CuaSocketRequest.send("permissions_status", configuration: configuration, deadline: .seconds(2)) else {
            return nil
        }
        if let pid = (status["source"] as? [String: Any])?["pid"] as? Int,
           let app = NSRunningApplication(processIdentifier: pid_t(pid))?.bundleURL, app.pathExtension == "app" {
            helperAppURL = app
        }
        return Self.permissions(status)
    }

    /// The two grants out of a `permissions_status` result.
    static func permissions(_ status: [String: Any]) -> ComputerUsePermissions {
        ComputerUsePermissions(accessibility: status["accessibility"] as? Bool ?? false,
                               screenRecording: status["screen_recording"] as? Bool ?? false)
    }
}
