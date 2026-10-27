public import CmuxNextDaemon
import Foundation

/// User-facing Cloud text. Keys live in Resources/Cloud.xcstrings (en, ja).
public enum CloudStrings {
    nonisolated public static var localBackend: String {
        String(localized: "cloud.unavailable.localBackend", defaultValue: "This build has no Cloud backend. Rebuild it with ./scripts/reload.sh --tag <tag> --direct-backend.", table: "Cloud", bundle: .module)
    }
    public static var noClient: String { String(localized: "cloud.unavailable.noClient", defaultValue: "The bundled cmux-tui client is missing, so Cloud machines cannot connect. Reinstall cmux from cmux.com/download, or rebuild a local build with cmux-tui bundled.", table: "Cloud", bundle: .module) }
    nonisolated public static var signInFirst: String { String(localized: "cloud.failed.signInFirst", defaultValue: "Sign in to use Cloud machines: run Sign In from the command palette, or `cmux cloud sign-in`.", table: "Cloud", bundle: .module) }
    public static var noMachine: String { String(localized: "cloud.failed.noMachine", defaultValue: "No Cloud machine is selected. Right-click a machine or pass --target machine:<id>; `cmux cloud list-machines` lists ids.", table: "Cloud", bundle: .module) }
    /// Why a Cloud machine needs an update, for its sidebar header and the
    /// Cloud diagnostics: the build it runs and what an update turns on.
    public static func compatibility(_ compat: DaemonCompatibility) -> String {
        switch compat.level {
        case .current: return ""
        // The missing capability ids stay in the Cloud diagnostics JSON
        // (`missing_features`); the text never shows them.
        case .limited:
            return String(format: String(localized: "cloud.compat.limitedUpdate", defaultValue: "This machine runs cmux-tui %@. Update it to turn on every feature of this app.", table: "Cloud", bundle: .module),
                          compat.versionLabel)
        case .incompatible:
            return String(localized: "cloud.compat.incompatibleUpdate", defaultValue: "This machine runs a cmux-tui this app cannot use. Update the machine to connect.", table: "Cloud", bundle: .module)
        }
    }
    /// A Cloud machine's link ended; v1 does not reconnect by itself.
    public static var linkDisconnected: String { String(localized: "cloud.link.disconnected", defaultValue: "Disconnected from the Cloud machine. Click Connect to connect again.", table: "Cloud", bundle: .module) }
    /// The app could not start or reach this Mac's connection helper.
    public static var linkHelperNotRunning: String { String(localized: "cloud.link.helperNotRunning", defaultValue: "The Cloud connection helper is not running on this Mac. Click Connect to start it.", table: "Cloud", bundle: .module) }
    public static var linkRevoked: String { String(localized: "cloud.link.revoked", defaultValue: "Access to this Cloud machine was revoked. Click Connect to connect again.", table: "Cloud", bundle: .module) }
    /// Close Workspace on the last row of a window for a machine that is not connected (a paused Cloud VM): nothing closes until it connects.
    public static func closeNotConnected(_ machine: String) -> String { String(format: String(localized: "cloud.workspace.closeNotConnected", defaultValue: "%@ is not connected. Resume or reconnect it to close its workspace.", table: "Cloud", bundle: .module), machine) }
    public static func linkFailed(_ detail: String) -> String {
        String(format: String(localized: "cloud.link.failed", defaultValue: "Could not connect to the Cloud machine (%@). Click Connect to try again.", table: "Cloud", bundle: .module), detail)
    }
    public static var notConnected: String { String(localized: "cloud.failed.notConnected", defaultValue: "The Cloud machine is not connected yet. Wait for it to connect; if it is paused, run `cmux cloud resume-machine --target machine:<id>`.", table: "Cloud", bundle: .module) }
    public static var commandRequired: String { String(localized: "cloud.failed.commandRequired", defaultValue: "Pass the command to run on the Cloud machine with --command \"<command>\".", table: "Cloud", bundle: .module) }
    public static var alreadySignedIn: String { String(localized: "cloud.failed.alreadySignedIn", defaultValue: "Already signed in. To switch accounts, run `cmux cloud sign-out`, then sign in again.", table: "Cloud", bundle: .module) }
    /// Team Picker's `team` names no team of this account.
    public static func noSuchTeam(_ team: String) -> String {
        String(format: String(localized: "cloud.failed.noSuchTeam", defaultValue: "No team named “%@” in this account.", table: "Cloud", bundle: .module), team)
    }
    public static var noTeams: String { String(localized: "cloud.failed.noTeams", defaultValue: "This account has no teams.", table: "Cloud", bundle: .module) }
    public static var invalidPort: String { String(localized: "cloud.failed.invalidPort", defaultValue: "Port must be between 1 and 65535.", table: "Cloud", bundle: .module) }
    public static var noAddress: String { String(localized: "cloud.failed.noAddress", defaultValue: "The machine has no private address yet. Check its state with `cmux cloud machine-status --target machine:<id>`; if it is paused, run `cmux cloud resume-machine --target machine:<id>` first.", table: "Cloud", bundle: .module) }
    public static var killMachineTitle: String { String(localized: "cloud.prompt.killMachine", defaultValue: "Kill this Cloud machine?", table: "Cloud", bundle: .module) }
    public static var killMachineBody: String { String(localized: "cloud.prompt.killMachineBody", defaultValue: "The machine and every terminal on it are deleted. This cannot be undone.", table: "Cloud", bundle: .module) }
    public static var kill: String { String(localized: "cloud.button.kill", defaultValue: "Kill Machine", table: "Cloud", bundle: .module) }
    public static var deleteSnapshotTitle: String { String(localized: "cloud.prompt.deleteSnapshot", defaultValue: "Delete this Cloud snapshot?", table: "Cloud", bundle: .module) }
    public static var deleteSnapshotBody: String { String(localized: "cloud.prompt.deleteSnapshotBody", defaultValue: "The snapshot is permanently deleted. This cannot be undone.", table: "Cloud", bundle: .module) }
    public static var deleteSnapshot: String { String(localized: "cloud.button.deleteSnapshot", defaultValue: "Delete Snapshot", table: "Cloud", bundle: .module) }
    /// The native confirmation of a Cloud machine create (cx-t2rz).
    public static var createConfirmTitle: String { String(localized: "cloud.create.confirm.title", defaultValue: "Create a Cloud machine?", table: "Cloud", bundle: .module) }
    /// The sidebar card of an agent's or a script's create (``createConfirmTitle`` above it).
    public static var createRequestDetail: String {
        String(localized: "cloud.create.request.detail", defaultValue: "Asked by an agent or a script. It counts against your Cloud plan.", table: "Cloud", bundle: .module)
    }
    public static var createConfirmApproval: String {
        String(localized: "cloud.create.confirm.approval", defaultValue: "The machine counts against your Cloud plan. Click Create to approve it.", table: "Cloud", bundle: .module)
    }
    public static var upgradeTitle: String { String(localized: "cloud.upgrade.title", defaultValue: "Cloud machines need a paid plan", table: "Cloud", bundle: .module) }
    public static func upgradeDetail(_ reason: CloudUpgradeReason) -> String {
        switch reason {
        case .freePlan, .server:
            String(localized: "cloud.upgrade.detail.free", defaultValue: "Your plan has no Cloud machines. The Go is $10 a month and includes machines; Pro is $50 a month.", table: "Cloud", bundle: .module)
        case .atLimit:
            String(localized: "cloud.upgrade.detail.limit", defaultValue: "All the running Cloud machines your plan allows are in use. Upgrade (Pro is $50 a month) or delete one.", table: "Cloud", bundle: .module)
        }
    }
    public static var upgradeButton: String { String(localized: "cloud.upgrade.button", defaultValue: "Upgrade", table: "Cloud", bundle: .module) }
    public static var notNow: String { String(localized: "cloud.upgrade.notNow", defaultValue: "Not now", table: "Cloud", bundle: .module) }
    nonisolated public static var upgradeRequired: String {
        String(localized: "cloud.upgrade.required", defaultValue: "No Cloud machine was created: your plan needs an upgrade. See cmux.com/pricing.", table: "Cloud", bundle: .module)
    }
    public static var createConfirmButton: String { String(localized: "cloud.create.confirm.button", defaultValue: "Create", table: "Cloud", bundle: .module) }
    nonisolated public static var createStillPending: String {
        String(localized: "cloud.create.stillPending", defaultValue: "The machine still waits for approval. Try again in a minute.", table: "Cloud", bundle: .module)
    }
    public static func createConfirmSize(cpu: Int, memoryGB: Int, diskGB: Int) -> String {
        String(format: String(localized: "cloud.create.confirm.size", defaultValue: "Size: %1$d vCPU, %2$d GB memory, %3$d GB disk", table: "Cloud", bundle: .module),
               cpu, memoryGB, diskGB)
    }
    public static func createConfirmName(_ name: String) -> String {
        String(format: String(localized: "cloud.create.confirm.name", defaultValue: "Name: %@", table: "Cloud", bundle: .module), name)
    }
    nonisolated public static var createApprovalMismatch: String {
        String(localized: "cloud.create.approvalMismatch", defaultValue: "The approval request does not match the machine you confirmed, so cmux did not approve it.", table: "Cloud", bundle: .module)
    }
    nonisolated public static var createApproveInFeed: String {
        String(localized: "cloud.create.approveInFeed", defaultValue: "Approve this machine in your cmux feed, then try again.", table: "Cloud", bundle: .module)
    }
    public static var cancel: String { String(localized: "cloud.button.cancel", defaultValue: "Cancel", table: "Cloud", bundle: .module) }
    /// A result toast: "<title>: <first line>".
    public static func result(_ title: String, _ summary: String) -> String {
        String(format: String(localized: "cloud.toast.result", defaultValue: "%1$@: %2$@", table: "Cloud", bundle: .module), title, summary)
    }
    public static var copy: String { String(localized: "cloud.button.copy", defaultValue: "Copy", table: "Cloud", bundle: .module) }
    public static var statusTitle: String { String(localized: "cloud.result.statusTitle", defaultValue: "Machine Status", table: "Cloud", bundle: .module) }
    public static var portsTitle: String { String(localized: "cloud.result.portsTitle", defaultValue: "Listening Ports", table: "Cloud", bundle: .module) }
    public static var toolsTitle: String { String(localized: "cloud.result.toolsTitle", defaultValue: "Machine Tools", table: "Cloud", bundle: .module) }
    public static var handoffTitle: String { String(localized: "cloud.result.handoffTitle", defaultValue: "Machine Handoff", table: "Cloud", bundle: .module) }
    public static var noPorts: String { String(localized: "cloud.result.noPorts", defaultValue: "No TCP ports are listening on this machine.", table: "Cloud", bundle: .module) }
    public static var diagnosticsTitle: String { String(localized: "cloud.result.diagnosticsTitle", defaultValue: "Cloud Diagnostics", table: "Cloud", bundle: .module) }
    public static var copyDetails: String { String(localized: "cloud.button.copyDetails", defaultValue: "Copy details", table: "Cloud", bundle: .module) }
    /// The Cloud diagnostics summary when nothing needs the person (the account's email).
    public static func diagnosticsAllWell(_ account: String) -> String {
        String(format: String(localized: "cloud.result.diagnosticsAllWell", defaultValue: "Signed in as %@. No Cloud problems found.", table: "Cloud", bundle: .module), account)
    }
    public static var snapshotTitle: String { String(localized: "cloud.result.snapshotTitle", defaultValue: "Snapshot Created", table: "Cloud", bundle: .module) }
    public static var templateTitle: String { String(localized: "cloud.result.templateTitle", defaultValue: "Template Created", table: "Cloud", bundle: .module) }
    public static var failedTitle: String { String(localized: "cloud.result.failedTitle", defaultValue: "Cloud Action Failed", table: "Cloud", bundle: .module) }

    public static var snapshotRequired: String { String(localized: "cloud.failed.snapshotRequired", defaultValue: "Pass the snapshot id with --snapshot <id>.", table: "Cloud", bundle: .module) }

    public static var filePathRequired: String { String(localized: "cloud.failed.filePathRequired", defaultValue: "Pass an absolute Cloud file path without '..'.", table: "Cloud", bundle: .module) }
    public static var fileContentsRequired: String { String(localized: "cloud.failed.fileContentsRequired", defaultValue: "Pass the file's contents with --contents \"<text>\".", table: "Cloud", bundle: .module) }
    public static var publicKeyRequired: String { String(localized: "cloud.failed.publicKeyRequired", defaultValue: "Pass an Ed25519 SSH public key with --public-key \"$(cat ~/.ssh/id_ed25519.pub)\".", table: "Cloud", bundle: .module) }
    /// Rotate Cloud Tunnel Key without a key: a WireGuard key, not an SSH one.
    public static var tunnelKeyRequired: String { String(localized: "cloud.failed.tunnelKeyRequired", defaultValue: "Pass this Mac's new WireGuard public key for the tunnel with --public-key <key>.", table: "Cloud", bundle: .module) }
    public static var filesTitle: String { String(localized: "cloud.result.filesTitle", defaultValue: "Cloud Files", table: "Cloud", bundle: .module) }
    public static var fileContentsTitle: String { String(localized: "cloud.result.fileContentsTitle", defaultValue: "Cloud File Contents", table: "Cloud", bundle: .module) }
    public static var fileStatTitle: String { String(localized: "cloud.result.fileStatTitle", defaultValue: "Cloud File Details", table: "Cloud", bundle: .module) }
    public static var scpTitle: String { String(localized: "cloud.result.scpTitle", defaultValue: "Cloud File Transfer", table: "Cloud", bundle: .module) }
    public static var firewallTitle: String { String(localized: "cloud.result.firewallTitle", defaultValue: "Cloud Firewall Rules", table: "Cloud", bundle: .module) }
    public static var networkTitle: String { String(localized: "cloud.result.networkTitle", defaultValue: "Cloud Networks", table: "Cloud", bundle: .module) }
    public static var removeFileTitle: String { String(localized: "cloud.prompt.removeFile", defaultValue: "Remove this Cloud file?", table: "Cloud", bundle: .module) }
    public static var removeFileBody: String { String(localized: "cloud.prompt.removeFileBody", defaultValue: "The selected file or directory is permanently removed.", table: "Cloud", bundle: .module) }
    public static var removeFile: String { String(localized: "cloud.button.removeFile", defaultValue: "Remove", table: "Cloud", bundle: .module) }
    public static var deleteFirewallRuleTitle: String { String(localized: "cloud.prompt.deleteFirewallRule", defaultValue: "Delete Cloud Firewall Rule?", table: "Cloud", bundle: .module) }
    public static var deleteFirewallRuleBody: String { String(localized: "cloud.prompt.deleteFirewallRuleBody", defaultValue: "This permanently removes the selected firewall rule.", table: "Cloud", bundle: .module) }
    public static var deleteFirewallRule: String { String(localized: "cloud.button.deleteFirewallRule", defaultValue: "Delete", table: "Cloud", bundle: .module) }

    public static func sizeMustBeOneOf(_ list: String) -> String {
        String(format: String(localized: "cloud.failed.sizeMustBeOneOf", defaultValue: "Size must be one of: %@.", table: "Cloud", bundle: .module), list)
    }

    public static func templateBody(_ id: String) -> String {
        String(format: String(localized: "cloud.result.templateBody", defaultValue: "Template %@ is ready. Start a machine from it with Restore Cloud Machine.", table: "Cloud", bundle: .module), id)
    }

    public static func snapshotBody(_ id: String) -> String {
        String(format: String(localized: "cloud.result.snapshotBody", defaultValue: "Snapshot %@ is ready. Restore it with Restore Cloud Machine.", table: "Cloud", bundle: .module), id)
    }
}

/// Why a Cloud create needs a plan upgrade (the upgrade card's text).
public enum CloudUpgradeReason: Equatable, Sendable {
    case freePlan, server
    case atLimit(Int)
}
