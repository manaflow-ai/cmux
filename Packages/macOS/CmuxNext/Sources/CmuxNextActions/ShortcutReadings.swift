/// The shortcuts one key-down may mean (``ActionRegistry/shortcuts(for:)``): none, one, or its
/// characters then its unshifted key ("}" then "]" for Shift-]). Held inline, so reading a key
/// allocates no array.
public nonisolated struct ShortcutReadings: RandomAccessCollection, Hashable, Sendable {
    private let head: Shortcut
    private let tail: Shortcut
    public let endIndex: Int

    public init() {
        let none = Shortcut("", modifiers: [])
        head = none
        tail = none
        endIndex = 0
    }

    public init(_ only: Shortcut) {
        head = only
        tail = only
        endIndex = 1
    }

    /// Two readings; one when they are the same shortcut.
    public init(_ first: Shortcut, _ second: Shortcut) {
        head = first
        tail = second
        endIndex = first == second ? 1 : 2
    }

    public var startIndex: Int { 0 }

    /// Index 0 is the first reading, 1 the second (valid only when ``count`` is 2).
    public subscript(position: Int) -> Shortcut {
        position == 0 ? head : tail
    }
}
