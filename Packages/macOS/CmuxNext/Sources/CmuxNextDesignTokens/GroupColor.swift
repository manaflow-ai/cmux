/// The nine group colors, shared by tab groups and workspace groups so
/// both render identically. The raw value is the stable token the daemon
/// stores and `cmux.json` / the CLI accept.
///
/// Group colors are user content, so blue is allowed here (the no-blue rule
/// covers app chrome). Every token is one hue at low saturation, tuned so a
/// window full of groups still reads as calm gray chrome.
public nonisolated enum GroupColor: String, CaseIterable, Codable, Hashable, Sendable {
    case grey
    case blue
    case red
    case yellow
    case green
    case pink
    case purple
    case cyan
    case orange

    /// The color a new group, space or browser profile gets: the first of
    /// `automaticOrder` not in `used`; never blue or grey. Nil when every
    /// such color is in use.
    public static func automatic(used: Set<String>) -> GroupColor? {
        automaticOrder.first { !used.contains($0.rawValue) }
    }

    /// The color a group with no stored color draws in: one of `automaticOrder`, picked from
    /// the group's id, so it is the same on every launch and machine (Leo 2026-10-20: groups
    /// made by agents and the CLI store none and all drew grey, as Chrome never does). A
    /// group someone colored grey keeps grey; only a missing color takes this.
    public static func unset(id: String) -> GroupColor {
        // FNV-1a: `hashValue` is seeded per process, so it would change the color each launch.
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in id.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01B3
        }
        return automaticOrder[Int(hash % UInt64(automaticOrder.count))]
    }

    /// The order the app gives new workspace groups, spaces and browser
    /// profiles their colors: the palette in its own order, without grey and
    /// blue (the no-blue rule covers what the app picks by itself).
    public static let automaticOrder: [GroupColor] = allCases.filter { $0 != .grey && $0 != .blue }

    /// The accents agent presence and machine colors pick from, in pick order (the ANSI accents by
    /// index, the two mixed ones, then blue, which presence may use because it is never the app's
    /// selection; `AgentPresenceColor`, `MachineColorOverrides`).
    package static let presenceOrder: [GroupColor] = [.red, .green, .yellow, .purple, .cyan, .orange, .pink, .blue]
}
