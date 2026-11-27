import Foundation

/// Counts writes to the parts of a value the client cache holds, so the store can tell in O(1)
/// whether the cached owner state moved (speed-of-sound-DESIGN.md 3.5: disk writes follow new
/// information, never events).
///
/// Equality and hashing ignore it: two mirrors or logs with the same content are equal whatever
/// their history. It only grows, so an unchanged count means no write happened since it was read.
public struct HomeChangeCount: Hashable, Sendable {
    /// The number of writes so far.
    public private(set) var value: UInt64 = 0

    /// A count of zero.
    public init() {}

    /// Notes one write.
    mutating func bump() { value &+= 1 }

    public static func == (_: Self, _: Self) -> Bool { true }
    public func hash(into _: inout Hasher) {}
}
