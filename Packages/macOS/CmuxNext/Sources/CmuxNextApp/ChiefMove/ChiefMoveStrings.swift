import Foundation

/// The "Move Chief To…" action's own refusals (Resources/Remote.xcstrings); the move's dialogs and
/// target names are the Home engine's (`ChiefTeleportStrings`).
nonisolated enum ChiefMoveStrings {
    static var noCLI: String { text("chiefMove.noCLI", "the bundled cmux CLI was not found") }
    static var targetRequired: String { text("chiefMove.targetRequired", "a target naming This Mac, a remote group or cloud is required") }
    static func unknownTarget(_ name: String) -> String { String(format: text("chiefMove.unknownTarget", "no move target named %@"), name) }
    static var running: String { text("chiefMove.running", "a Chief move or rollback is already running") }
    static var notMoved: String { text("chiefMove.notMoved", "this Chief runs on this Mac: there is no move to roll back") }

    private static func text(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, table: "Remote", bundle: .module)
    }
}
