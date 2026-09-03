import AppKit
import Foundation
import os

private let cloudTunnelRepairLog = Logger(subsystem: "com.cmuxterm.app", category: "CloudTunnelRepair")

/// The single in-app path that brings the Cloud VM tunnel up, so every surface
/// offering "Connect Network" runs exactly the same thing.
///
/// `cmux vpn up` shells out to `wg-quick`, which asks for a password once per
/// boot, so the repair has to run somewhere with a tty. That rules out
/// ``CloudVMActionLauncher``, whose child has both pipes wired to `Pipe()` and
/// therefore no way to answer the prompt. A local terminal pane does have one,
/// and it is also where the user can read what `wg-quick` says.
///
/// The command is the *bundled* CLI pointed at this app's own socket, never a
/// bare `cmux` from `PATH`: each deployment owns its own tunnel (`cmux` for
/// release builds, `cmux-dev`/`cmux-staging` for dev ones), so a tagged build
/// has to repair its own rather than the release one.
enum CloudTunnelRepairAction {
    /// The button title, shared by every surface that offers the repair.
    static var title: String {
        String(localized: "cloud.tunnel.down.action.connect", defaultValue: "Connect Network")
    }

    /// The bundled CLI, when this build ships one. Nil in test hosts and in any
    /// build without `Resources/bin/cmux`, which is why callers must check
    /// ``isAvailable`` before advertising the action.
    static var bundledCLIPath: String? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("bin/cmux"),
              FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        return url.path
    }

    /// Whether a surface can offer the action at all.
    static var isAvailable: Bool { bundledCLIPath != nil }

    /// `cmux --socket <this app> vpn up`, or nil when no bundled CLI exists.
    static func command(cliPath: String?, socketPath: String?) -> [String]? {
        guard let cliPath else { return nil }
        var argv = [cliPath]
        if let socketPath, !socketPath.isEmpty {
            argv += ["--socket", socketPath]
        }
        argv += ["vpn", "up"]
        return argv
    }

    /// Opens a focused local terminal pane running the repair. Fire-and-forget:
    /// the pane itself reports success or failure, and a surface that could not
    /// even create the pane logs rather than stacking a second alert on the
    /// first one.
    @MainActor
    static func run() {
        guard let argv = command(
            cliPath: bundledCLIPath,
            socketPath: TerminalController.shared.currentSocketPathForRemoteRestore()
        ) else { return }
        Task {
            do {
                _ = try await TerminalController.surfaceNewTerminal(
                    machine: .local,
                    command: argv,
                    cwd: nil,
                    name: title,
                    remoteWorkspaceID: nil,
                    destination: nil,
                    focus: true
                )
            } catch {
                cloudTunnelRepairLog.error("vpn up pane failed: \(String(reflecting: error), privacy: .public)")
            }
        }
    }

    /// Runs `alert`, first appending the repair button when `error` is a
    /// tunnel-down failure this build can fix, and performing the repair when
    /// the user picks it. Every cloud failure alert goes through here so the
    /// button reads and behaves the same everywhere.
    @MainActor
    static func runModal(_ alert: NSAlert, for error: Error) {
        guard (error as? VMClientError)?.isTunnelDown == true, isAvailable else {
            alert.runModal()
            return
        }
        alert.addButton(withTitle: title)
        let repairIndex = alert.buttons.count - 1
        let response = alert.runModal()
        let repairResponse = NSApplication.ModalResponse(
            rawValue: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + repairIndex
        )
        guard response == repairResponse else { return }
        run()
    }
}
