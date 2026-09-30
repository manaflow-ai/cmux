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
    static var alreadySignedIn: String { String(localized: "cloud.failed.alreadySignedIn", defaultValue: "Already signed in.", table: "Cloud", bundle: .module) }
    static var noTeams: String { String(localized: "cloud.failed.noTeams", defaultValue: "This account has no teams.", table: "Cloud", bundle: .module) }
    static var promoteTemplate: String { String(localized: "cloud.unavailable.promoteTemplate", defaultValue: "The web API has no route to promote a machine to a template yet.", table: "Cloud", bundle: .module) }
    static var tools: String { String(localized: "cloud.unavailable.tools", defaultValue: "The machine tools panel is not ported to cmux-next yet; use Machine Status, Ports, or Diagnostics.", table: "Cloud", bundle: .module) }
    static var handoff: String { String(localized: "cloud.unavailable.handoff", defaultValue: "Handing off a machine needs the session sharing flow, which is not ported to cmux-next yet.", table: "Cloud", bundle: .module) }
    static var mobilePairing: String { String(localized: "cloud.unavailable.mobilePairing", defaultValue: "Mobile pairing arrives with the iOS phase of cmux-next (plans/cmux-next/cloud-ios.md).", table: "Cloud", bundle: .module) }
    static var invalidPort: String { String(localized: "cloud.failed.invalidPort", defaultValue: "Port must be between 1 and 65535.", table: "Cloud", bundle: .module) }
    static var noAddress: String { String(localized: "cloud.failed.noAddress", defaultValue: "The machine has no private address yet.", table: "Cloud", bundle: .module) }
    static var renameMachineTitle: String { String(localized: "cloud.prompt.renameMachine", defaultValue: "Rename Machine", table: "Cloud", bundle: .module) }
    static var killMachineTitle: String { String(localized: "cloud.prompt.killMachine", defaultValue: "Kill this Cloud machine?", table: "Cloud", bundle: .module) }
    static var killMachineBody: String { String(localized: "cloud.prompt.killMachineBody", defaultValue: "The machine and every terminal on it are deleted. This cannot be undone.", table: "Cloud", bundle: .module) }
    static var kill: String { String(localized: "cloud.button.kill", defaultValue: "Kill Machine", table: "Cloud", bundle: .module) }
    static var cancel: String { String(localized: "cloud.button.cancel", defaultValue: "Cancel", table: "Cloud", bundle: .module) }
    static var ok: String { String(localized: "cloud.button.ok", defaultValue: "OK", table: "Cloud", bundle: .module) }
    static var rename: String { String(localized: "cloud.button.rename", defaultValue: "Rename", table: "Cloud", bundle: .module) }
    static var select: String { String(localized: "cloud.button.select", defaultValue: "Select", table: "Cloud", bundle: .module) }
    static var copy: String { String(localized: "cloud.button.copy", defaultValue: "Copy", table: "Cloud", bundle: .module) }
    static var teamPickerTitle: String { String(localized: "cloud.prompt.teamPicker", defaultValue: "Choose a Team", table: "Cloud", bundle: .module) }
    static var statusTitle: String { String(localized: "cloud.result.statusTitle", defaultValue: "Machine Status", table: "Cloud", bundle: .module) }
    static var portsTitle: String { String(localized: "cloud.result.portsTitle", defaultValue: "Listening Ports", table: "Cloud", bundle: .module) }
    static var noPorts: String { String(localized: "cloud.result.noPorts", defaultValue: "No TCP ports are listening on this machine.", table: "Cloud", bundle: .module) }
    static var diagnosticsTitle: String { String(localized: "cloud.result.diagnosticsTitle", defaultValue: "Cloud Diagnostics", table: "Cloud", bundle: .module) }
    static var snapshotTitle: String { String(localized: "cloud.result.snapshotTitle", defaultValue: "Snapshot Created", table: "Cloud", bundle: .module) }
    static var failedTitle: String { String(localized: "cloud.result.failedTitle", defaultValue: "Cloud Action Failed", table: "Cloud", bundle: .module) }

    static var snapshotRequired: String { String(localized: "cloud.failed.snapshotRequired", defaultValue: "Pass the snapshot id to restore (--snapshot <id>).", table: "Cloud", bundle: .module) }

    static func sizeMustBeOneOf(_ list: String) -> String {
        String(format: String(localized: "cloud.failed.sizeMustBeOneOf", defaultValue: "Size must be one of: %@.", table: "Cloud", bundle: .module), list)
    }

    static func snapshotBody(_ id: String) -> String {
        String(format: String(localized: "cloud.result.snapshotBody", defaultValue: "Snapshot %@ is ready. Restore it with Restore Cloud Machine.", table: "Cloud", bundle: .module), id)
    }
}
