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

    /// A source over the default socket, or nil when this Mac has no
    /// cmux-cua daemon socket (onboarding then leaves the step out).
    static func local() -> AppComputerUsePermissionSource? {
        let configuration = AgentActivitySocketSource.Configuration.standard(machineName: "")
        guard FileManager.default.fileExists(atPath: configuration.socketPath) else { return nil }
        return AppComputerUsePermissionSource(configuration: configuration)
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
