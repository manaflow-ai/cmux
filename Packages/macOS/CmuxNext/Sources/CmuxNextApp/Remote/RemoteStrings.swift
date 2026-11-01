import CmuxNextRemote
import CmuxNextRemoteLocalhostService
import Foundation

/// User-facing SSH machine text. Keys live in Resources/Remote.xcstrings. One accessor per line
/// (the CmuxNextApp size cap, scripts/cmux-next/check-app-size.sh).
enum RemoteStrings {
    // Remote-terminal tab placeholder (plans/cmux-next/data-model.md 1.4).
    static func placeholderReconnecting(_ machine: String) -> String { String(format: String(localized: "remote.terminal.reconnecting", defaultValue: "Reconnecting to %@…", table: "Remote", bundle: .module), machine) }
    /// The one-list sidebar's pending row of an SSH machine that is connecting (cx-gaq9).
    static func sidebarConnecting(_ machine: String) -> String { String(format: String(localized: "remote.sidebar.connecting", defaultValue: "Connecting to %@…", table: "Remote", bundle: .module), machine) }
    static func placeholderOffline(_ machine: String) -> String { String(format: String(localized: "remote.terminal.offline", defaultValue: "%@ is offline", table: "Remote", bundle: .module), machine) }
    static func placeholderUnknown(_ machine: String) -> String { String(format: String(localized: "remote.terminal.unknown", defaultValue: "%@ is not connected on this Mac", table: "Remote", bundle: .module), machine) }
    // An agent chat tab whose session another Mac's acpmux runs.
    static func agentTabElsewhere(_ machine: String) -> String { String(format: String(localized: "remote.agentTab.elsewhere", defaultValue: "This chat runs on %@", table: "Remote", bundle: .module), machine) }
    static var agentTabElsewhereUnknown: String { String(localized: "remote.agentTab.elsewhereUnknown", defaultValue: "This chat runs on another Mac", table: "Remote", bundle: .module) }
    static var placeholderConnect: String { String(localized: "remote.terminal.connect", defaultValue: "Connect", table: "Remote", bundle: .module) }
    static var placeholderNoSnapshot: String { String(localized: "remote.terminal.noSnapshot", defaultValue: "No saved screen", table: "Remote", bundle: .module) }
    static func terminalOn(_ machine: String) -> String { String(format: String(localized: "remote.terminal.title", defaultValue: "Terminal on %@", table: "Remote", bundle: .module), machine) }
    static var moveTabAcrossMachines: String { String(localized: "remote.tab.cannotMoveAcrossMachines", defaultValue: "Home, conversation and app tabs cannot move to a workspace on another machine.", table: "Remote", bundle: .module) }
    static func openRemoteHostNotFound(_ host: String) -> String { String(format: String(localized: "remote.openRemote.hostNotFound", defaultValue: "No machine named %@ is added. Add it first, or check the name.", table: "Remote", bundle: .module), host) }
    static func openRemoteBadRatio(_ text: String) -> String { String(format: String(localized: "remote.openRemote.badRatio", defaultValue: "The ratio %@ must be a number between 0 and 1.", table: "Remote", bundle: .module), text) }
    static var splitRightOrDown: String { String(localized: "remote.terminal.splitRightOrDown", defaultValue: "A terminal from another machine can split right or down only.", table: "Remote", bundle: .module) }
    static var needsRemoteTerminalTabs: String { String(localized: "remote.terminal.needsCapability", defaultValue: "This workspace's machine runs a cmux-tui without terminals from other machines. Update it first.", table: "Remote", bundle: .module) }
    static var machineHasNoTerminal: String { String(localized: "remote.terminal.noResource", defaultValue: "That machine's cmux-tui cannot name the terminal. Update it first.", table: "Remote", bundle: .module) }
    static var signInToCheck: String { String(localized: "remote.joined.signInToCheck", defaultValue: "Sign in to cmux to check this machine.", table: "Remote", bundle: .module) }
    static var checkStopped: String { String(localized: "remote.joined.checkStopped", defaultValue: "The check stopped before it finished. Try again.", table: "Remote", bundle: .module) }
    // The Touch ID or password confirm's reasons for Settings' switches that widen another machine's access (SettingsPageProvider.widen).
    static var fullAccessConfirmReason: String { String(localized: "settings.personGate.fullAccessReason", defaultValue: "turn on Full access, so another machine's chats can edit files and run commands on this Mac without asking", table: "Remote", bundle: .module) }
    static var vmHostConfirmReason: String { String(localized: "settings.personGate.vmHostReason", defaultValue: "turn on Dedicated agent machine, so this Mac's chats run on that Cloud machine without the sandbox", table: "Remote", bundle: .module) }
    static var noClient: String { String(localized: "remote.unavailable.noClient", defaultValue: "The bundled cmux-tui is missing, so SSH machines cannot connect.", table: "Remote", bundle: .module) }
    static var noMachine: String { String(localized: "remote.failed.noMachine", defaultValue: "No SSH machine is selected. Choose Connect to Machine in the command palette, or pass --machine <name>.", table: "Remote", bundle: .module) }
    static var workspaceNotOnSSHMachine: String { String(localized: "remote.failed.workspaceNotSSH", defaultValue: "This workspace does not run on an SSH machine.", table: "Remote", bundle: .module) }
    static var tabNotOnSSHMachine: String { String(localized: "remote.failed.tabNotSSH", defaultValue: "This tab does not run on an SSH machine.", table: "Remote", bundle: .module) }
    static func unknownMachine(_ name: String) -> String { String(format: String(localized: "remote.failed.unknownMachine", defaultValue: "No SSH machine is named “%@”.", table: "Remote", bundle: .module), name) }
    static func newWorkspaceFailed(_ name: String, _ error: Error) -> String {
        String(format: String(localized: "remote.failed.newWorkspace", defaultValue: "Couldn’t create a workspace on %1$@: %2$@",
                              table: "Remote", bundle: .module), name, String(describing: error))
    }
    static func notConnected(_ name: String) -> String { String(format: String(localized: "remote.failed.notConnected", defaultValue: "%@ is not connected yet.", table: "Remote", bundle: .module), name) }
    static func invalidDestination(_ text: String, _ error: SSHDestinationError?) -> String {
        if error == .password {
            return String(localized: "remote.failed.password", defaultValue: "cmux never takes passwords. Use your SSH key or agent.", table: "Remote", bundle: .module)
        }
        return String(format: String(localized: "remote.failed.destination", defaultValue: "“%@” is not an SSH destination. Use user@host, a host from your SSH config, or host:port.", table: "Remote", bundle: .module), text)
    }
    static func invalidSession(_ name: String) -> String { String(format: String(localized: "remote.failed.session", defaultValue: "“%@” is not a session name. Use letters, digits, dots, dashes and underscores.", table: "Remote", bundle: .module), name) }
    static func invalidPath(_ path: String) -> String { String(format: String(localized: "remote.failed.path", defaultValue: "“%@” is not a usable path. Use a plain path, optionally starting with ~/.", table: "Remote", bundle: .module), path) }
    static var noPinnedBuild: String { String(localized: "remote.failed.noPinnedBuild", defaultValue: "This build does not know which cmux-tui to install.", table: "Remote", bundle: .module) }
    static func unsupportedPlatform(_ name: String) -> String { String(format: String(localized: "remote.failed.unsupportedPlatform", defaultValue: "cmux-tui has no build for %@. It runs on macOS and Linux (x86_64 and arm64).", table: "Remote", bundle: .module), name) }
    static var retry: String { String(localized: "remote.recovery.retry", defaultValue: "Retry", table: "Remote", bundle: .module) }
    static var copyError: String { String(localized: "remote.recovery.copyError", defaultValue: "Copy Error", table: "Remote", bundle: .module) }
    static var checkMachine: String { String(localized: "remote.recovery.checkMachine", defaultValue: "Check Machine", table: "Remote", bundle: .module) }
    static var connectTitle: String { String(localized: "remote.connect.title", defaultValue: "Connect to Machine", table: "Remote", bundle: .module) }
    static var notARemoteGroup: String { String(localized: "remote.removeGroup.notAGroup", defaultValue: "This machine is not a remote group.", table: "Remote", bundle: .module) }
    static var newGroupTitle: String { String(localized: "remote.newGroup.title", defaultValue: "New Remote Group", table: "Remote", bundle: .module) }
    static var connect: String { String(localized: "remote.button.connect", defaultValue: "Connect", table: "Remote", bundle: .module) }
    static func connectFailedTitle(_ name: String) -> String { String(format: String(localized: "remote.connect.failedTitle", defaultValue: "Cannot Connect to %@", table: "Remote", bundle: .module), name) }

    // MARK: Install and forget prompts

    static func installTitle(_ name: String) -> String { String(format: String(localized: "remote.install.title", defaultValue: "Install cmux-tui on %@?", table: "Remote", bundle: .module), name) }
    static func installBody(commit: String, path: String, destination: String) -> String { String(format: String(localized: "remote.install.body", defaultValue: "Downloads cmux-tui %1$@ from files.cmux.com, checks its SHA-256 checksum and installs it at %2$@ on %3$@, without sudo. A cmux-tui running there restarts on the new build; its terminals keep running.", table: "Remote", bundle: .module), commit, path, destination) }
    static var install: String { String(localized: "remote.button.install", defaultValue: "Install", table: "Remote", bundle: .module) }
    /// cx-3r9mt: an older cmux-tui on a machine that is not idle; the person starts the update.
    static func updateTitle(_ name: String) -> String { String(format: String(localized: "remote.update.title", defaultValue: "Update available on %@", table: "Remote", bundle: .module), name) }
    static func updateBody(commit: String, path: String, machine: String) -> String { String(format: String(localized: "remote.update.body", defaultValue: "%1$@ runs an older cmux-tui. Agents or chats run there now, so cmux does not update it by itself. Update installs cmux-tui %2$@ at %3$@; terminals and agents keep running.", table: "Remote", bundle: .module), machine, commit, path) }
    static var update: String { String(localized: "remote.button.update", defaultValue: "Update", table: "Remote", bundle: .module) }
    /// The toast after Forget Machine (its Undo brings the machine back).
    static func forgotToast(_ name: String) -> String { String(format: String(localized: "remote.forgot.toast", defaultValue: "Forgot %@", table: "Remote", bundle: .module), name) }

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
        case .treeNotPublished(let key):
            return String(format: String(localized: "remote.install.treeNotPublished",
                                         defaultValue: "This build's cmux-tui (tree %@) is not published, so it cannot be installed on the machine. Use a build whose cmux-tui is published.",
                                         table: "Remote", bundle: .module), String(key.prefix(12)))
        case .unrunnable(let detail):
            return String(format: String(localized: "remote.install.unrunnable", defaultValue: "The downloaded cmux-tui does not run on this machine: %@", table: "Remote", bundle: .module), detail)
        case .notWritable(let detail):
            return String(format: String(localized: "remote.install.notWritable", defaultValue: "cmux-tui cannot be written there: %@", table: "Remote", bundle: .module), detail)
        default:
            return String(format: String(localized: "remote.install.failed", defaultValue: "The install failed: %@", table: "Remote", bundle: .module), String(describing: install))
        }
    }

    static func sshFailed(_ message: String) -> String { String(format: String(localized: "remote.failed.ssh", defaultValue: "SSH failed: %@", table: "Remote", bundle: .module), message) }

    // MARK: Status details (sidebar header tooltip, remote.machines)

    /// Why the machine is in its state, or nil when nothing needs saying.
    static func detail(_ session: SSHMachineSession) -> String? {
        switch session.linkStatus {
        case .offline:
            return String(localized: "remote.status.offline", defaultValue: "Disconnected. Choose Reconnect Machine to connect.", table: "Remote", bundle: .module)
        case .connecting, .connected:
            if let failure = session.daemonFailure { return plainFailure(failure.error, machine: session.host.label) }
            return session.lastError
        case .reconnecting:
            return String(localized: "remote.status.reconnecting", defaultValue: "The connection dropped. cmux reconnects on its own; programs keep running on the machine.", table: "Remote", bundle: .module)
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
            return plainFailure(message, machine: session.host.label)
        }
    }

    static func plainFailure(_ raw: String, machine: String) -> String {
        switch RemoteFailureCause(raw) {
        case .sessionInUse: String(format: String(localized: "remote.failure.sessionInUse", defaultValue: "Another cmux on %1$@ holds this session. Update cmux on %1$@, then choose Retry.", table: "Remote", bundle: .module), machine)
        case let .cause(cause): String(format: String(localized: "remote.failure.cause", defaultValue: "cmux on %1$@ stopped: %2$@. Choose Copy Error for the details.", table: "Remote", bundle: .module), machine, cause)
        case .unknown: String(format: String(localized: "remote.failure.unknown", defaultValue: "cmux on %@ stopped. Choose Copy Error for the details.", table: "Remote", bundle: .module), machine)
        }
    }

    /// The machine's raw failure (ssh's own words, or the install or link
    /// error) for Copy SSH Error; nil when it has none.
    static func sshError(_ session: SSHMachineSession) -> String? {
        let text: String? = switch session.linkStatus {
        case .authFailed(let message), .hostKeyUntrusted(let message), .unreachable(let message),
             .installFailed(let message), .failed(let message): message
        case .needsInstall(let need): needText(need, session)
        case .connecting, .connected, .reconnecting: session.daemonFailure?.error ?? session.lastError
        case .offline, .installing: session.lastError
        }
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    /// The one-time notice of a browser tab opened in another machine's
    /// workspace: the page renders and runs on this Mac (cx-2cob slice 1a).
    static func browserRunsOnThisMac(_ machine: String) -> String {
        String(format: String(localized: "remote.browser.runsOnThisMac",
                              defaultValue: "This tab runs on this Mac, not on %@.", table: "Remote", bundle: .module), machine)
    }

    /// The notice under a browser tab of another machine's workspace, by what
    /// its `localhost` reaches: forwarded to the machine, or this Mac (and why).
    /// No route (unknown) keeps the plain text.
    static func browserRunsOnThisMac(_ machine: String, route: RemoteLocalhostRoute?) -> String {
        switch route {
        case .machine(let name):
            return String(format: String(localized: "remote.browser.runsOnThisMac.forwarded",
                                         defaultValue: "This tab runs on this Mac. localhost goes to %@.",
                                         table: "Remote", bundle: .module), name)
        case .thisMacInstead(let name, let reason):
            let why: String = switch reason {
            case .turnedOff:
                String(localized: "remote.browser.localhostReason.turnedOff",
                       defaultValue: "forwarding is turned off", table: "Remote", bundle: .module)
            case .updateMachine:
                String(format: String(localized: "remote.browser.localhostReason.updateMachine",
                                      defaultValue: "%@ needs a cmux update", table: "Remote", bundle: .module), name)
            case .webKit:
                String(localized: "remote.browser.localhostReason.webKit",
                       defaultValue: "WebKit tabs cannot forward localhost", table: "Remote", bundle: .module)
            }
            return String(format: String(localized: "remote.browser.runsOnThisMac.fallback",
                                         defaultValue: "This tab runs on this Mac, and localhost is this Mac too (%@).",
                                         table: "Remote", bundle: .module), why)
        case .thisMac, nil:
            return browserRunsOnThisMac(machine)
        }
    }

    /// The refusal of a new browser tab in a workspace of a machine that is not connected.
    static func browserMachineNotConnected(_ machine: String) -> String {
        String(format: String(localized: "remote.browser.notConnected",
                              defaultValue: "%@ is not connected. Reconnect it to open a browser tab in its workspace.",
                              table: "Remote", bundle: .module), machine)
    }

    /// The refusal of Copy SSH Error for a machine without a failure.
    static func noSSHError(_ machine: String) -> String { String(format: String(localized: "remote.copyError.none", defaultValue: "%@ has no SSH error to copy.", table: "Remote", bundle: .module), machine) }

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
        case .refused(let refusal):
            return refusalText(refusal)
        }
    }

    /// The one table from the bundled cmux-tui's typed refusal codes to text.
    static func refusalText(_ refusal: RemoteRefusal) -> String {
        switch refusal {
        case .protocolOlder:
            String(localized: "remote.refusal.protocolOlder", defaultValue: "The cmux-tui there is too old for this connection. Install cmux-tui to update it.", table: "Remote", bundle: .module)
        case .protocolNewer:
            String(localized: "remote.refusal.protocolNewer", defaultValue: "The cmux-tui there is newer than this app. Update cmux on this Mac to connect.", table: "Remote", bundle: .module)
        case .wrongApp:
            String(localized: "remote.refusal.wrongApp", defaultValue: "Another program is at the cmux-tui path there. Install cmux-tui to replace it.", table: "Remote", bundle: .module)
        case .distributionMismatch:
            String(localized: "remote.refusal.distributionMismatch", defaultValue: "The cmux-tui there is a different release than this app uses. Install cmux-tui to replace it.", table: "Remote", bundle: .module)
        case .buildMismatch:
            String(localized: "remote.refusal.buildMismatch", defaultValue: "The cmux-tui there is a different build than this app uses. Install cmux-tui to replace it.", table: "Remote", bundle: .module)
        }
    }
}
