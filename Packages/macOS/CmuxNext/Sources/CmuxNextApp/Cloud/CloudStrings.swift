import CmuxNextDaemon
import Foundation

/// User-facing Cloud text. Keys live in Resources/Cloud.xcstrings (en, ja).
enum CloudStrings {
    static var localBackend: String {
        String(localized: "cloud.unavailable.localBackend", defaultValue: "This build has no Cloud backend. Rebuild it with ./scripts/reload.sh --tag <tag> --direct-backend.", table: "Cloud", bundle: .module)
    }
    static var noClient: String { String(localized: "cloud.unavailable.noClient", defaultValue: "The bundled cmux-tui client is missing, so Cloud machines cannot connect.", table: "Cloud", bundle: .module) }
    static var signInFirst: String { String(localized: "cloud.failed.signInFirst", defaultValue: "Sign in to use Cloud machines.", table: "Cloud", bundle: .module) }
    static var noMachine: String { String(localized: "cloud.failed.noMachine", defaultValue: "No Cloud machine is selected. Right-click a machine or pass --target machine:<id>.", table: "Cloud", bundle: .module) }
    /// Why a Cloud machine needs an update, for its sidebar header and the
    /// Cloud diagnostics: the build it runs and what an update turns on.
    static func compatibility(_ compat: DaemonCompatibility) -> String {
        switch compat.level {
        case .current: return ""
        case .limited:
            return String(format: String(localized: "cloud.compat.limited", defaultValue: "This machine runs cmux-tui %1$@. Update it to turn on: %2$@.", table: "Cloud", bundle: .module),
                          compat.versionLabel, compat.missingOptional.joined(separator: ", "))
        case .incompatible:
            return String(format: String(localized: "cloud.compat.incompatible", defaultValue: "This machine runs a cmux-tui this app cannot use (%@). Update the machine to connect.", table: "Cloud", bundle: .module),
                          compat.missingRequired.joined(separator: ", "))
        }
    }
    static var notConnected: String { String(localized: "cloud.failed.notConnected", defaultValue: "The Cloud machine is not connected yet.", table: "Cloud", bundle: .module) }
    static var commandRequired: String { String(localized: "cloud.failed.commandRequired", defaultValue: "Pass a command to run on the Cloud machine.", table: "Cloud", bundle: .module) }
    static var alreadySignedIn: String { String(localized: "cloud.failed.alreadySignedIn", defaultValue: "Already signed in.", table: "Cloud", bundle: .module) }
    static var noTeams: String { String(localized: "cloud.failed.noTeams", defaultValue: "This account has no teams.", table: "Cloud", bundle: .module) }
    static var mobilePairing: String { String(localized: "cloud.unavailable.mobilePairing", defaultValue: "Mobile pairing arrives with the iOS phase of cmux-next (plans/cmux-next/cloud-ios.md).", table: "Cloud", bundle: .module) }
    static var invalidPort: String { String(localized: "cloud.failed.invalidPort", defaultValue: "Port must be between 1 and 65535.", table: "Cloud", bundle: .module) }
    static var noAddress: String { String(localized: "cloud.failed.noAddress", defaultValue: "The machine has no private address yet.", table: "Cloud", bundle: .module) }
    static var renameMachineTitle: String { String(localized: "cloud.prompt.renameMachine", defaultValue: "Rename Machine", table: "Cloud", bundle: .module) }
    static var killMachineTitle: String { String(localized: "cloud.prompt.killMachine", defaultValue: "Kill this Cloud machine?", table: "Cloud", bundle: .module) }
    static var killMachineBody: String { String(localized: "cloud.prompt.killMachineBody", defaultValue: "The machine and every terminal on it are deleted. This cannot be undone.", table: "Cloud", bundle: .module) }
    static var kill: String { String(localized: "cloud.button.kill", defaultValue: "Kill Machine", table: "Cloud", bundle: .module) }
    static var deleteSnapshotTitle: String { String(localized: "cloud.prompt.deleteSnapshot", defaultValue: "Delete this Cloud snapshot?", table: "Cloud", bundle: .module) }
    static var deleteSnapshotBody: String { String(localized: "cloud.prompt.deleteSnapshotBody", defaultValue: "The snapshot is permanently deleted. This cannot be undone.", table: "Cloud", bundle: .module) }
    static var deleteSnapshot: String { String(localized: "cloud.button.deleteSnapshot", defaultValue: "Delete Snapshot", table: "Cloud", bundle: .module) }
    static var cancel: String { String(localized: "cloud.button.cancel", defaultValue: "Cancel", table: "Cloud", bundle: .module) }
    static var ok: String { String(localized: "cloud.button.ok", defaultValue: "OK", table: "Cloud", bundle: .module) }
    static var rename: String { String(localized: "cloud.button.rename", defaultValue: "Rename", table: "Cloud", bundle: .module) }
    static var select: String { String(localized: "cloud.button.select", defaultValue: "Select", table: "Cloud", bundle: .module) }
    static var copy: String { String(localized: "cloud.button.copy", defaultValue: "Copy", table: "Cloud", bundle: .module) }
    static var teamPickerTitle: String { String(localized: "cloud.prompt.teamPicker", defaultValue: "Choose a Team", table: "Cloud", bundle: .module) }
    static var statusTitle: String { String(localized: "cloud.result.statusTitle", defaultValue: "Machine Status", table: "Cloud", bundle: .module) }
    static var portsTitle: String { String(localized: "cloud.result.portsTitle", defaultValue: "Listening Ports", table: "Cloud", bundle: .module) }
    static var toolsTitle: String { String(localized: "cloud.result.toolsTitle", defaultValue: "Machine Tools", table: "Cloud", bundle: .module) }
    static var handoffTitle: String { String(localized: "cloud.result.handoffTitle", defaultValue: "Machine Handoff", table: "Cloud", bundle: .module) }
    static var noPorts: String { String(localized: "cloud.result.noPorts", defaultValue: "No TCP ports are listening on this machine.", table: "Cloud", bundle: .module) }
    static var diagnosticsTitle: String { String(localized: "cloud.result.diagnosticsTitle", defaultValue: "Cloud Diagnostics", table: "Cloud", bundle: .module) }
    static var snapshotTitle: String { String(localized: "cloud.result.snapshotTitle", defaultValue: "Snapshot Created", table: "Cloud", bundle: .module) }
    static var templateTitle: String { String(localized: "cloud.result.templateTitle", defaultValue: "Template Created", table: "Cloud", bundle: .module) }
    static var failedTitle: String { String(localized: "cloud.result.failedTitle", defaultValue: "Cloud Action Failed", table: "Cloud", bundle: .module) }

    static var snapshotRequired: String { String(localized: "cloud.failed.snapshotRequired", defaultValue: "Pass the snapshot id to restore (--snapshot <id>).", table: "Cloud", bundle: .module) }

    static var filePathRequired: String { String(localized: "cloud.failed.filePathRequired", defaultValue: "Pass an absolute Cloud file path without '..'.", table: "Cloud", bundle: .module) }
    static var fileContentsRequired: String { String(localized: "cloud.failed.fileContentsRequired", defaultValue: "Pass file contents to write.", table: "Cloud", bundle: .module) }
    static var publicKeyRequired: String { String(localized: "cloud.failed.publicKeyRequired", defaultValue: "Pass an Ed25519 SSH public key for the transfer.", table: "Cloud", bundle: .module) }
    static var filesTitle: String { String(localized: "cloud.result.filesTitle", defaultValue: "Cloud Files", table: "Cloud", bundle: .module) }
    static var fileContentsTitle: String { String(localized: "cloud.result.fileContentsTitle", defaultValue: "Cloud File Contents", table: "Cloud", bundle: .module) }
    static var fileStatTitle: String { String(localized: "cloud.result.fileStatTitle", defaultValue: "Cloud File Details", table: "Cloud", bundle: .module) }
    static var scpTitle: String { String(localized: "cloud.result.scpTitle", defaultValue: "Cloud File Transfer", table: "Cloud", bundle: .module) }
    static var removeFileTitle: String { String(localized: "cloud.prompt.removeFile", defaultValue: "Remove this Cloud file?", table: "Cloud", bundle: .module) }
    static var removeFileBody: String { String(localized: "cloud.prompt.removeFileBody", defaultValue: "The selected file or directory is permanently removed.", table: "Cloud", bundle: .module) }
    static var removeFile: String { String(localized: "cloud.button.removeFile", defaultValue: "Remove", table: "Cloud", bundle: .module) }

    static func sizeMustBeOneOf(_ list: String) -> String {
        String(format: String(localized: "cloud.failed.sizeMustBeOneOf", defaultValue: "Size must be one of: %@.", table: "Cloud", bundle: .module), list)
    }

    static func templateBody(_ id: String) -> String {
        String(format: String(localized: "cloud.result.templateBody", defaultValue: "Template %@ is ready. Start a machine from it with Restore Cloud Machine.", table: "Cloud", bundle: .module), id)
    }

    static func snapshotBody(_ id: String) -> String {
        String(format: String(localized: "cloud.result.snapshotBody", defaultValue: "Snapshot %@ is ready. Restore it with Restore Cloud Machine.", table: "Cloud", bundle: .module), id)
    }
}
