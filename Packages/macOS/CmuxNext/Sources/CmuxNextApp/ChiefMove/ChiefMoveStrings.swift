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

    private static func text(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, table: "Remote", bundle: .module)
    }
}
