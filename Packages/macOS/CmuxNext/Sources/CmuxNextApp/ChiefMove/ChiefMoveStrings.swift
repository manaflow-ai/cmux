import Foundation

/// The "Move Chief To…" texts (Resources/Remote.xcstrings).
nonisolated enum ChiefMoveStrings {
    static var cloud: String { text("chiefMove.cloud", "cmux Cloud") }
    static var move: String { text("chiefMove.move", "Move") }
    static var noCLI: String { text("chiefMove.noCLI", "the bundled cmux CLI was not found") }
    static var targetRequired: String { text("chiefMove.targetRequired", "a target naming This Mac, a remote group or cloud is required") }
    static func unknownTarget(_ name: String) -> String { String(format: text("chiefMove.unknownTarget", "no move target named %@"), name) }
    static func offline(_ name: String) -> String { String(format: text("chiefMove.offline", "%@ (offline)"), name) }
    static func noSSHRoute(_ name: String) -> String { String(format: text("chiefMove.noSSHRoute", "%@ (no SSH route)"), name) }
    static func signIn(_ name: String) -> String { String(format: text("chiefMove.signIn", "%@ (sign in first)"), name) }
    static func confirmTitle(_ name: String) -> String { String(format: text("chiefMove.confirmTitle", "Move Chief to %@?"), name) }
    static func doneTitle(_ name: String) -> String { String(format: text("chiefMove.doneTitle", "Chief moved to %@"), name) }
    static func failedTitle(_ name: String) -> String { String(format: text("chiefMove.failedTitle", "Chief did not move to %@"), name) }
    static var running: String { text("chiefMove.running", "a Chief move or rollback is already running") }
    static var notMoved: String { text("chiefMove.notMoved", "this Chief runs on this Mac: there is no move to roll back") }
    static var rollbackConfirmTitle: String { text("chiefMove.rollbackConfirmTitle", "Roll back the Chief's last move?") }
    static var rollbackConfirmBody: String {
        text("chiefMove.rollbackConfirmBody",
             "The Chief answers from this Mac again, as it was before the move. What it learned at the other place since then stays there.")
    }
    static var rollbackButton: String { text("chiefMove.rollbackButton", "Roll Back") }
    static var rolledBackTitle: String { text("chiefMove.rolledBackTitle", "Chief rolled back to this Mac") }
    static var rollbackFailedTitle: String { text("chiefMove.rollbackFailedTitle", "Chief did not roll back") }

    private static func text(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, table: "Remote", bundle: .module)
    }
}
