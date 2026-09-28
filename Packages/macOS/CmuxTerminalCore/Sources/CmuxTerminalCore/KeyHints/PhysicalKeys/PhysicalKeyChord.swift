/// Physical keys to press together: modifier keys held, then one key.
public struct PhysicalKeyChord: Hashable, Sendable {
    /// Keys held down, in the order shown.
    public var modifiers: [PhysicalKey]
    /// The key pressed while the modifiers are held.
    public var key: PhysicalKey

    /// - Parameters:
    ///   - modifiers: Keys held down; shown in macOS order (⇪, fn, ⌃, ⌥, ⇧, ⌘).
    ///   - key: The key pressed while they are held.
    public init(modifiers: [PhysicalKey], key: PhysicalKey) {
        self.modifiers = modifiers.sorted { Self.displayRank($0) < Self.displayRank($1) }
        self.key = key
    }

    /// Key cap glyphs, such as `⇪O` or `fn ⌃O`.
    public var glyphs: String {
        var text = ""
        for modifier in modifiers {
            text += modifier.glyph
            if modifier == .fn { text += " " }
        }
        return text + key.glyph
    }

    /// Right-hand modifier keys in the chord, which its glyphs can't show.
    public var rightHandModifiers: [PhysicalKey] {
        modifiers.filter(\.isRightModifier)
    }

    /// Every key in the chord, modifiers first.
    var allKeys: [PhysicalKey] { modifiers + [key] }

    private static func displayRank(_ key: PhysicalKey) -> Int {
        if key == .capsLock { return 0 }
        if key == .fn { return 1 }
        switch key.modifier {
        case .control: return 2
        case .option: return 3
        case .shift: return 4
        case .command: return 5
        case nil: return 6
        }
    }
}
