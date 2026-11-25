/// One row of the which-key overlay: the key after the leader and the
/// action it runs.
public struct WhichKeyRow: Equatable {
    public var key: String
    public var title: String
    /// False when the action cannot run in this focus (drawn dimmed).
    public var isEnabled: Bool

    public init(key: String, title: String, isEnabled: Bool) {
        self.key = key
        self.title = title
        self.isEnabled = isEnabled
    }
}

/// The overlay's own text (WhichKey.xcstrings).
public enum WhichKeyStrings {
    static var cancelHint: String {
        String(localized: "whichKey.cancelHint", defaultValue: "esc to cancel", table: "WhichKey", bundle: .module)
    }

    /// A key that leads to longer chords.
    public static var moreKeys: String {
        String(localized: "whichKey.moreKeys", defaultValue: "more keys…", table: "WhichKey", bundle: .module)
    }

    static var accessibilityLabel: String {
        String(localized: "whichKey.accessibilityLabel", defaultValue: "Leader keys", table: "WhichKey", bundle: .module)
    }
}
