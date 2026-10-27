// Wire ids of the method tables (MethodTable.swift): `family << 8 | ordinal`.

/// A command or v2 operation id: `family << 8 | ordinal`.
public struct MethodID: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let rawValue: UInt16

    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    /// The family byte.
    public var family: UInt8 { UInt8(truncatingIfNeeded: rawValue >> 8) }

    /// The ordinal within the family.
    public var ordinal: UInt8 { UInt8(truncatingIfNeeded: rawValue) }

    public var description: String { MethodTable.hex(rawValue) }

    public static func < (lhs: MethodID, rhs: MethodID) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// An event id: `family << 8 | ordinal`, family 0xC0-0xFE.
public struct EventID: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let rawValue: UInt16

    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    /// The family byte.
    public var family: UInt8 { UInt8(truncatingIfNeeded: rawValue >> 8) }

    /// The ordinal within the family.
    public var ordinal: UInt8 { UInt8(truncatingIfNeeded: rawValue) }

    public var description: String { MethodTable.hex(rawValue) }

    public static func < (lhs: EventID, rhs: EventID) -> Bool { lhs.rawValue < rhs.rawValue }
}
