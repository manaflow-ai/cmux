/// Modifier keys that take part in copy-mode matching, without AppKit. The
/// terminal view maps `NSEvent.ModifierFlags` into this set.
public struct CopyModeModifiers: OptionSet, Equatable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let command = CopyModeModifiers(rawValue: 1 << 0)
    public static let shift = CopyModeModifiers(rawValue: 1 << 1)
    public static let control = CopyModeModifiers(rawValue: 1 << 2)
    /// Ignored when matching.
    public static let numericPad = CopyModeModifiers(rawValue: 1 << 3)
    /// Ignored when matching.
    public static let function = CopyModeModifiers(rawValue: 1 << 4)
    /// Ignored when matching, except that it keeps a capital letter from
    /// counting as Shift.
    public static let capsLock = CopyModeModifiers(rawValue: 1 << 5)
}

/// State kept between key events of one copy-mode session: the count prefix
/// and a pending `y` or `g`.
public struct CopyModeInputState: Equatable, Sendable {
    public var countPrefix: Int?
    public var pendingYankLine: Bool
    public var pendingG: Bool

    public init(countPrefix: Int? = nil, pendingYankLine: Bool = false, pendingG: Bool = false) {
        self.countPrefix = countPrefix
        self.pendingYankLine = pendingYankLine
        self.pendingG = pendingG
    }

    public mutating func reset() {
        countPrefix = nil
        pendingYankLine = false
        pendingG = false
    }
}
