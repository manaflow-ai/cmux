public import Foundation

/// `appearance.backgroundRecents` (schemas/settings/source/appearance.json): the backgrounds shown
/// before, newest first. The daemon's settings write records it (cmux-config schema/backdrop.rs
/// record_recent); the app only validates and reads it.
extension BackdropSelectionSetting {
    /// At most this many recents (cmux-config RECENTS_CAP).
    public static let recentsCap = 8

    /// Whether a value is valid for `appearance.backgroundRecents`: an array of at most
    /// ``recentsCap`` different background values.
    static func acceptsRecents(_ value: JSONValue) -> Bool {
        guard let items = value.arrayValue, items.count <= recentsCap else { return false }
        var seen = Set<String>()
        return items.allSatisfy { item in
            guard let text = item.stringValue, accepts(item) else { return false }
            return seen.insert(text).inserted
        }
    }

    /// The valid recents in `root`, newest first.
    public static func recents(in root: JSONValue) -> [String] {
        guard let items = root.value(at: recentsPath)?.arrayValue else { return [] }
        var seen = Set<String>()
        return items.compactMap { item in
            guard let text = item.stringValue, accepts(item), seen.insert(text).inserted else { return nil }
            return text
        }
    }

    /// The background Switch to Previous Background goes to: the newest recent that is not the
    /// current one (cmux-config previous_background).
    public static func previous(in root: JSONValue) -> String? {
        let current = root.value(at: configPath)?.stringValue ?? fallback
        return recents(in: root).first { $0 != current }
    }
}
