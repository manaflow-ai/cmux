import CmuxNextRemote
import Foundation

/// User-facing SSH machine text. Keys live in Resources/Remote.xcstrings.
enum RemoteStrings {
    // Remote-terminal tab placeholder (plans/cmux-next/data-model.md 1.4).
    static func placeholderReconnecting(_ machine: String) -> String {
        String(format: String(localized: "remote.terminal.reconnecting", defaultValue: "Reconnecting to %@…", table: "Remote", bundle: .module), machine)
    }
    static func placeholderOffline(_ machine: String) -> String {
        String(format: String(localized: "remote.terminal.offline", defaultValue: "%@ is offline", table: "Remote", bundle: .module), machine)
    }
    static func placeholderUnknown(_ machine: String) -> String {
        String(format: String(localized: "remote.terminal.unknown", defaultValue: "%@ is not connected on this Mac", table: "Remote", bundle: .module), machine)
    }
    static var placeholderConnect: String {
        String(localized: "remote.terminal.connect", defaultValue: "Connect", table: "Remote", bundle: .module)
    }
    static var placeholderNoSnapshot: String {
        String(localized: "remote.terminal.noSnapshot", defaultValue: "No saved screen", table: "Remote", bundle: .module)
    }
    static func terminalOn(_ machine: String) -> String {
        String(format: String(localized: "remote.terminal.title", defaultValue: "Terminal on %@", table: "Remote", bundle: .module), machine)
    }
    static var moveBrowserAcrossMachines: String {
        String(localized: "remote.terminal.moveBrowser", defaultValue: "Browser tabs cannot move to a workspace on another machine yet.", table: "Remote", bundle: .module)
    }
    static var needsRemoteTerminalTabs: String {
        String(localized: "remote.terminal.needsCapability", defaultValue: "This workspace's machine runs a cmux-tui without terminals from other machines. Update it first.", table: "Remote", bundle: .module)
    }
    static var machineHasNoTerminal: String {
        String(localized: "remote.terminal.noResource", defaultValue: "That machine's cmux-tui cannot name the terminal. Update it first.", table: "Remote", bundle: .module)
    }
    static var noClient: String {
        String(localized: "remote.unavailable.noClient", defaultValue: "The bundled cmux-tui is missing, so SSH machines cannot connect.", table: "Remote", bundle: .module)
    }
    static var noMachine: String {
        String(localized: "remote.failed.noMachine", defaultValue: "No SSH machine is selected. Right-click a machine or pass --machine <name>.", table: "Remote", bundle: .module)
    }
    static func unknownMachine(_ name: String) -> String {
        String(format: String(localized: "remote.failed.unknownMachine", defaultValue: "No SSH machine is named “%@”.", table: "Remote", bundle: .module), name)
    }
    static func notConnected(_ name: String) -> String {
        String(format: String(localized: "remote.failed.notConnected", defaultValue: "%@ is not connected yet.", table: "Remote", bundle: .module), name)
    }
    static func invalidDestination(_ text: String, _ error: SSHDestinationError?) -> String {
        if error == .password {
            return String(localized: "remote.failed.password", defaultValue: "cmux never takes passwords. Use your SSH key or agent.", table: "Remote", bundle: .module)
        }
        return String(format: String(localized: "remote.failed.destination", defaultValue: "“%@” is not an SSH destination. Use user@host, a host from your SSH config, or host:port.", table: "Remote", bundle: .module), text)
    }
    static func invalidSession(_ name: String) -> String {
        String(format: String(localized: "remote.failed.session", defaultValue: "“%@” is not a session name. Use letters, digits, dots, dashes and underscores.", table: "Remote", bundle: .module), name)
    }
    static func invalidPath(_ path: String) -> String {
        String(format: String(localized: "remote.failed.path", defaultValue: "“%@” is not a usable path. Use a plain path, optionally starting with ~/.", table: "Remote", bundle: .module), path)
    }
    static var noPinnedBuild: String {
        String(localized: "remote.failed.noPinnedBuild", defaultValue: "This build does not know which cmux-tui to install.", table: "Remote", bundle: .module)
    }
    static func unsupportedPlatform(_ name: String) -> String {
        String(format: String(localized: "remote.failed.unsupportedPlatform", defaultValue: "cmux-tui has no build for %@. It runs on macOS and Linux (x86_64 and arm64).", table: "Remote", bundle: .module), name)
    }
    static var connectTitle: String {
        String(localized: "remote.connect.title", defaultValue: "Connect to Machine", table: "Remote", bundle: .module)
    }
    static var connect: String { String(localized: "remote.button.connect", defaultValue: "Connect", table: "Remote", bundle: .module) }
    static func connectFailedTitle(_ name: String) -> String {
        String(format: String(localized: "remote.connect.failedTitle", defaultValue: "Cannot Connect to %@", table: "Remote", bundle: .module), name)
    }

    // MARK: Install and forget prompts

    static func installTitle(_ name: String) -> String {
        String(format: String(localized: "remote.install.title", defaultValue: "Install cmux-tui on %@?", table: "Remote", bundle: .module), name)
    }
    static func installBody(commit: String, path: String, destination: String) -> String {
        String(format: String(localized: "remote.install.body", defaultValue: "Downloads cmux-tui %1$@ from files.cmux.com, checks its SHA-256 checksum and installs it at %2$@ on %3$@, without sudo. A cmux-tui running there restarts on the new build; its terminals keep running.", table: "Remote", bundle: .module), commit, path, destination)
    }
    static var install: String { String(localized: "remote.button.install", defaultValue: "Install", table: "Remote", bundle: .module) }
    static func forgetTitle(_ name: String) -> String {
        String(format: String(localized: "remote.forget.title", defaultValue: "Forget %@?", table: "Remote", bundle: .module), name)
    }
    static var forgetBody: String {
        String(localized: "remote.forget.body", defaultValue: "Removes the machine from the saved list with its personal order, groups and space pins. Nothing on the machine changes.", table: "Remote", bundle: .module)
    }
    static var forget: String { String(localized: "remote.button.forget", defaultValue: "Forget", table: "Remote", bundle: .module) }

    // MARK: Failures

    static func installFailure(_ error: any Error) -> String {
        if let failure = error as? SSHFailure { return sshFailed(failure.message) }
        guard let install = error as? RemoteInstallError else {
            return String(format: String(localized: "remote.install.failed", defaultValue: "The install failed: %@", table: "Remote", bundle: .module), String(describing: error))
        }
        switch install {
        case .checksumMismatch:
            return String(localized: "remote.install.checksum", defaultValue: "The download did not match its SHA-256 checksum. Nothing was replaced.", table: "Remote", bundle: .module)
        case .noChecksumTool:
            return String(localized: "remote.install.noChecksumTool", defaultValue: "The machine has no sha256sum or shasum, so the download cannot be checked.", table: "Remote", bundle: .module)
        case .downloadFailed(let detail):
            return String(format: String(localized: "remote.install.download", defaultValue: "The download failed: %@", table: "Remote", bundle: .module), detail)
        case .unrunnable(let detail):
            return String(format: String(localized: "remote.install.unrunnable", defaultValue: "The downloaded cmux-tui does not run on this machine: %@", table: "Remote", bundle: .module), detail)
        case .notWritable(let detail):
            return String(format: String(localized: "remote.install.notWritable", defaultValue: "cmux-tui cannot be written there: %@", table: "Remote", bundle: .module), detail)
        default:
            return String(format: String(localized: "remote.install.failed", defaultValue: "The install failed: %@", table: "Remote", bundle: .module), String(describing: install))
        }
    }

    static func sshFailed(_ message: String) -> String {
        String(format: String(localized: "remote.failed.ssh", defaultValue: "SSH failed: %@", table: "Remote", bundle: .module), message)
    }

    // MARK: Status details (sidebar header tooltip, remote.machines)

    /// Why the machine is in its state, or nil when nothing needs saying.
    static func detail(_ session: SSHMachineSession) -> String? {
        switch session.linkStatus {
        case .offline:
            return String(localized: "remote.status.offline", defaultValue: "Disconnected. Choose Reconnect Machine to connect.", table: "Remote", bundle: .module)
        case .connecting, .connected:
            return session.lastError
        case .authFailed(let message):
            return String(format: String(localized: "remote.status.authFailed", defaultValue: "SSH sign-in failed: %@ Check your key or agent, then choose Reconnect Machine.", table: "Remote", bundle: .module), message)
        case .hostKeyUntrusted(let message):
            return String(format: String(localized: "remote.status.hostKey", defaultValue: "The host key is not trusted: %1$@ Run ssh %2$@ in a terminal to check it. cmux never skips host key checks.", table: "Remote", bundle: .module), message, session.host.destination.sshArgument)
        case .unreachable(let message):
            return String(format: String(localized: "remote.status.unreachable", defaultValue: "Cannot reach the machine: %@ cmux tries again when the network changes.", table: "Remote", bundle: .module), message)
        case .needsInstall(let need):
            return needText(need, session)
        case .installing:
            return String(localized: "remote.status.installing", defaultValue: "Installing cmux-tui…", table: "Remote", bundle: .module)
        case .installFailed(let message), .failed(let message):
            return message
        }
    }

    static func needText(_ need: InstallNeed, _ session: SSHMachineSession) -> String {
        switch need {
        case .none: return ""
        case .missing:
            return String(localized: "remote.need.missing", defaultValue: "cmux-tui is not installed there. Choose Install cmux-tui on Machine….", table: "Remote", bundle: .module)
        case .unrunnable(let detail):
            return String(format: String(localized: "remote.need.unrunnable", defaultValue: "The cmux-tui there does not run (%@). Install cmux-tui to replace it.", table: "Remote", bundle: .module), detail)
        case .protocolMismatch(let remote, let local):
            return String(format: String(localized: "remote.need.protocol", defaultValue: "The cmux-tui there speaks link protocol %1$d; this app needs %2$d. Install cmux-tui to update it.", table: "Remote", bundle: .module), remote, local)
        case .wrongApp(let app):
            return String(format: String(localized: "remote.need.wrongApp", defaultValue: "%@ is at the cmux-tui path there. Install cmux-tui to replace it.", table: "Remote", bundle: .module), app)
        case .unsupportedPlatform:
            return unsupportedPlatform(session.host.label)
        }
    }
}
