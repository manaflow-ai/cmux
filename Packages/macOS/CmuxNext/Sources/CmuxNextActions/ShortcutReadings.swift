/// The shortcuts one key-down may mean (``ActionRegistry/shortcuts(for:)-(KeyInput)``), in the order
/// the binding table tries them: none, or up to ``capacity`` distinct readings. Held inline, so
/// reading a key allocates no array (p04-input-055).
public nonisolated struct ShortcutReadings: RandomAccessCollection, Hashable, Sendable {
    /// The most readings one key has: the text, the Command map's unshifted key, the physical
    /// digit, the key-equivalent reading, the unshifted key, the ASCII-capable layout's key and the
    /// US position of moved punctuation.
    public static let capacity = 7

    private var slots: (Shortcut, Shortcut, Shortcut, Shortcut, Shortcut, Shortcut, Shortcut)
    public private(set) var endIndex: Int

    public init() {
        let none = Shortcut("", modifiers: [])
        slots = (none, none, none, none, none, none, none)
        endIndex = 0
    }

    public init(_ only: Shortcut) {
        self.init()
        append(only)
    }

    /// Two readings; one when they are the same shortcut.
    public init(_ first: Shortcut, _ second: Shortcut) {
        self.init()
        append(first)
        append(second)
    }

    /// Adds `reading` after the others unless it is already one of them, or the key has
    /// ``capacity`` readings.
    public mutating func append(_ reading: Shortcut) {
        guard endIndex < Self.capacity, !contains(reading) else { return }
        switch endIndex {
        case 0: slots.0 = reading
        case 1: slots.1 = reading
        case 2: slots.2 = reading
        case 3: slots.3 = reading
        case 4: slots.4 = reading
        case 5: slots.5 = reading
        default: slots.6 = reading
        }
        endIndex += 1
    }

    public var startIndex: Int { 0 }

    /// Index 0 is the first reading; valid below ``endIndex``.
    public subscript(position: Int) -> Shortcut {
        switch position {
        case 0: slots.0
        case 1: slots.1
        case 2: slots.2
        case 3: slots.3
        case 4: slots.4
        case 5: slots.5
        default: slots.6
        }
    }

    public static func == (lhs: ShortcutReadings, rhs: ShortcutReadings) -> Bool {
        lhs.elementsEqual(rhs)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(endIndex)
        for reading in self { hasher.combine(reading) }
    }
}
