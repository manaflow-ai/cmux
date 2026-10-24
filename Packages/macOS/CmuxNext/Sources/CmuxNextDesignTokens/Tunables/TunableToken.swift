public import Foundation

/// The identity of one declared tunable, made with its descriptor: a store reads its override and
/// its Observation key by this identity (a pointer), not by hashing the dotted key string. A read
/// of a tunable runs on hot paths (every sidebar row, every tab item), and the string's hash and
/// the key path made from it were most of such a read (sweep 2026-10-23: 67 ms in one STRESS
/// palette.openCmuxSettingsFile, in `TunableStore.override`).
public nonisolated final class TunableToken: Hashable, Sendable {
    public init() {}

    public static func == (lhs: TunableToken, rhs: TunableToken) -> Bool { lhs === rhs }
    public func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}
