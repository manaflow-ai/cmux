import Foundation

/// Strings of the server UI (Resources/Localizable.xcstrings). Few labels
/// by design: glyphs and dots carry state. Alert titles and bodies come
/// from the server (they carry live numbers); check names are ours.
nonisolated enum ServerStrings {
    private static func t(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, bundle: .module)
    }

    static var title: String { t("panel.title", "Server") }
    static var serving: String { t("status.serving", "Serving") }
    static var off: String { t("status.off", "Off") }
    static var unpaired: String { t("status.unpaired", "Not paired") }
    static var pairing: String { t("status.pairing", "Pairing") }
    static var attention: String { t("status.attention", "Needs attention") }
    static var unreachable: String { t("status.unreachable", "Server is not running") }

    static var terminals: String { t("row.terminals", "Terminals") }
    static var apps: String { t("row.apps", "Apps") }
    static var database: String { t("row.database", "Database") }
    static var browser: String { t("row.browser", "Browser") }
    static var automations: String { t("row.automations", "Automations") }
    static var health: String { t("row.health", "Health") }
    static var devices: String { t("row.devices", "Devices") }
    static var allGood: String { t("health.ok", "All good") }
    static var noAlerts: String { t("health.none", "No alerts") }
    static var resolved: String { t("health.resolved", "Resolved") }
    static var pinned: String { t("store.pinned", "Pinned") }

    static var revoke: String { t("action.revoke", "Revoke") }
    static var pairThisServer: String { t("action.pair", "Pair This Server") }
    static var needsAdmin: String { t("fix.admin", "Asks for an administrator once") }
    static var elsewhere: String { t("app.elsewhere", "On another host") }
    static var zeroLoss: String { t("app.zeroLoss", "Zero-loss data") }

    static func expires(_ time: String) -> String {
        String(format: t("pairing.expires", "Expires %@"), time)
    }
    static var scan: String { t("pairing.scan", "Scan with a signed-in device") }
    static var enterCode: String { t("pairing.enter", "Enter this code on a signed-in device") }
    static var wordsMatch: String { t("pairing.words", "Approve only if these words match") }
    static var paired: String { t("pairing.paired", "Paired") }
    static var code: String { t("pairing.code", "Code") }

    static var addServer: String { t("approver.title", "Add Server") }
    static var team: String { t("approver.team", "Team") }
    static var name: String { t("approver.name", "Name") }
    static var approve: String { t("approver.approve", "Approve") }
    static var cancel: String { t("approver.cancel", "Cancel") }
    static var runChief: String { t("approver.runChief", "Run my Chief on this server") }

    static func chiefOn(_ server: String) -> String {
        String(format: t("chief.on", "Chief on %@"), server)
    }
    static var noReplyYet: String { t("chief.noReply", "No reply yet") }

    static func state(_ state: ChiefPlacementStatus.State) -> String {
        switch state {
        case .ready: t("chief.ready", "Ready")
        case .thinking: t("chief.thinking", "Thinking")
        case .notAnswering: t("chief.notAnswering", "Not answering")
        }
    }

    static func state(_ state: ServerRoleState) -> String {
        switch state {
        case .on: serving
        case .off: off
        case .starting: t("state.starting", "Starting")
        case .failed: t("state.failed", "Failed")
        case .unavailable: t("state.unavailable", "Unavailable")
        }
    }

    static func state(_ state: AppServerState) -> String {
        switch state {
        case .running: serving
        case .stopped: off
        case .starting: t("state.starting", "Starting")
        case .draining: t("state.draining", "Draining")
        case .crashloop: t("state.crashloop", "Crash loop")
        }
    }

    /// The check's name, neutral so it reads for a passing check too.
    static func check(_ id: HealthCheckID, fallback: String) -> String {
        switch id {
        case .onBattery: t("check.power", "Power")
        case .offline: t("check.network", "Internet")
        case .diskLow: t("check.disk", "Disk space")
        case .lockPending: t("check.lock", "Screen lock")
        case .sleepEnabled: t("check.sleep", "Sleep")
        case .noAutoRestart: t("check.autoRestart", "Restart after power loss")
        case .fileVaultWait: t("check.fileVault", "FileVault at restart")
        case .notLoggedIn: t("check.login", "Start without login")
        case .lingerOff: t("check.linger", "Run after logout")
        case .encryptionOff: t("check.encryption", "Disk encryption")
        case .postgresQuota: t("check.quota", "Database quota")
        case .backupStale: t("check.backup", "Backups")
        default: fallback
        }
    }
}
