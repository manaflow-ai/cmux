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

    private static func format(_ key: StaticString, _ value: String.LocalizationValue, _ argument: String) -> String {
        String(format: text(key, value), argument)
    }

    private static func text(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, table: "Home", bundle: .module)
    }
}
