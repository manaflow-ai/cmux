import Foundation

/// The Chief teleport texts (Resources/Home.xcstrings).
nonisolated enum ChiefTeleportStrings {
    static var thisMac: String { text("home.teleport.thisMac", "This Mac") }
    static var cloud: String { text("home.teleport.cloud", "cmux Cloud") }
    static var menuTitle: String { text("home.teleport.menuTitle", "Teleport Chief") }
    static var rollback: String { text("home.teleport.rollback", "Roll Back Last Move") }
    static var rollingBack: String { text("home.teleport.rollingBack", "Rolling back…") }
    static var rolledBack: String { text("home.teleport.rolledBack", "Rolled back to This Mac") }
    static var help: String { text("home.teleport.help", "Moves the Chief to another Mac or to cmux Cloud") }
    /// The Chief card's row label.
    static var row: String { text("home.teleport.row", "Runs On") }
    static func checking(_ name: String) -> String { format("home.teleport.checking", "Checking %@…", name) }
    static func moving(_ name: String) -> String { format("home.teleport.moving", "Moving to %@…", name) }
    static func verifying(_ name: String) -> String { format("home.teleport.verifying", "Verifying %@…", name) }
    static func done(_ name: String) -> String { format("home.teleport.done", "Moved to %@", name) }
    static func failed(_ name: String) -> String { format("home.teleport.failed", "Move to %@ failed", name) }
    /// Home's header chip when the Chief moved to a host Home cannot open from here.
    static func awayOn(_ host: String) -> String { format("home.teleport.awayOn", "Chief is on %@", host) }
    /// VoiceOver: "Chief location: cmux Cloud".
    static func label(_ place: String) -> String { format("home.teleport.label", "Chief location: %@", place) }

    // Move Chief To… (the keys moved here from the app's Remote table with the move's code).
    static func offline(_ name: String) -> String { format("chiefMove.offline", "%@ (offline)", name) }
    static func noSSHRoute(_ name: String) -> String { format("chiefMove.noSSHRoute", "%@ (no SSH route)", name) }
    static func signIn(_ name: String) -> String { format("chiefMove.signIn", "%@ (sign in first)", name) }
    static var move: String { text("chiefMove.move", "Move") }
    static func confirmTitle(_ name: String) -> String { format("chiefMove.confirmTitle", "Move Chief to %@?", name) }
    static func doneTitle(_ name: String) -> String { format("chiefMove.doneTitle", "Chief moved to %@", name) }
    static func failedTitle(_ name: String) -> String { format("chiefMove.failedTitle", "Chief did not move to %@", name) }
    static var rollbackConfirmTitle: String { text("chiefMove.rollbackConfirmTitle", "Roll back the Chief's last move?") }
    static var rollbackConfirmBody: String {
        text("chiefMove.rollbackConfirmBody",
             "The Chief answers from this Mac again, as it was before the move. What it learned at the other place since then stays there.")
    }
    static var rollbackButton: String { text("chiefMove.rollbackButton", "Roll Back") }
    static var rolledBackTitle: String { text("chiefMove.rolledBackTitle", "Chief rolled back to this Mac") }
    static var rollbackFailedTitle: String { text("chiefMove.rollbackFailedTitle", "Chief did not roll back") }

    private static func format(_ key: StaticString, _ value: String.LocalizationValue, _ argument: String) -> String {
        String(format: text(key, value), argument)
    }

    private static func text(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, table: "Home", bundle: .module)
    }
}
