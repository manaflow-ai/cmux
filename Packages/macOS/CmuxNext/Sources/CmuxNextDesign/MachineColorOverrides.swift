public import CmuxTheme
public import CmuxNextDesignTokens

/// The colors people picked for machines (`appearance.machineColors` in cmux.json): a machine's
/// color key (`MachineColor.key`) to `#RRGGBB`, or to one of the accents MachineColor picks from
/// (red, green, yellow, purple, cyan, orange, pink, blue), which follows the theme as the
/// automatic color does. A machine with no pick keeps its automatic color.
public nonisolated struct MachineColorOverrides: Hashable, Sendable {
    /// One machine's pick.
    public nonisolated enum Pick: Hashable, Sendable {
        case accent(GroupColor)
        case rgb(ThemeRGB)
    }

    /// Color key to pick.
    public private(set) var picks: [String: Pick] = [:]
    /// The automatic accent of each machine the person has (``assigningAutomatic(names:)``): its name's
    /// hash accent unless a pick or a machine before it already draws that accent, then the next free
    /// one, so no two of a person's machines share a color while a free accent is left (Leo, 2026-11-28:
    /// "we can have them be delineated"). A machine not listed keeps its hash accent.
    public private(set) var automatic: [String: GroupColor] = [:]

    public static let none = MachineColorOverrides()

    public init() {}

    /// `entries` as cmux.json writes them; keys are normalized as `MachineColor.key` (two
    /// spellings of one machine: the first in key order wins), and an entry that names no color
    /// or no machine is left out (the setting's parser reports it).
    public init(_ entries: [String: String]) {
        for (name, value) in entries.sorted(by: { $0.key < $1.key }) {
            let key = MachineColor(name: name).key
            guard !key.isEmpty, picks[key] == nil, let pick = Self.pick(value) else { continue }
            picks[key] = pick
        }
    }

    public var isEmpty: Bool { picks.isEmpty }

    /// The pick `value` names: `#RRGGBB`, or an accent's name; nil for anything else.
    public static func pick(_ value: String) -> Pick? {
        if let accent = GroupColor(rawValue: value), AgentPresenceColor.order.contains(accent) { return .accent(accent) }
        guard value.count == 7, value.first == "#", let rgb = ThemeRGB(cssHex: value) else { return nil }
        return .rgb(rgb)
    }

    /// These picks with ``automatic`` assigned over `names` (the machines the person has, This Mac
    /// left out: it draws no color). Names are keyed as `MachineColor.key` and taken in key order, so
    /// one set of machines draws one set of colors on every surface and every run.
    public func assigningAutomatic(names: [String]) -> MachineColorOverrides {
        var next = self
        next.automatic = Self.automaticAccents(keys: names.map { MachineColor(name: $0).key }, picks: picks)
        return next
    }

    /// Each key's accent, no two alike while a free accent is left: the hash accent
    /// (AgentPresenceColor), else the next accent in pick order that no pick and no earlier key draws.
    static func automaticAccents(keys: [String], picks: [String: Pick]) -> [String: GroupColor] {
        let order = AgentPresenceColor.order
        var taken = Set(picks.values.compactMap { pick -> GroupColor? in
            if case .accent(let accent) = pick { return accent }
            return nil
        })
        var assigned: [String: GroupColor] = [:]
        for key in Set(keys).sorted() where !key.isEmpty && picks[key] == nil {
            let start = AgentPresenceColor.index(forKey: key, count: order.count)
            let free = (0 ..< order.count).lazy.map { order[(start + $0) % order.count] }.first { !taken.contains($0) }
            let accent = free ?? order[start]
            assigned[key] = accent
            taken.insert(accent)
        }
        return assigned
    }

    /// The automatic accent of the machine keyed `key` in `tokens`' palette; nil for a machine not assigned.
    public func automaticRGB(forKey key: String, tokens: ThemeTokens) -> ThemeRGB? {
        automatic[key].map { AgentPresenceColor.rgb(of: $0, tokens: tokens) }
    }

    /// The color picked for the machine keyed `key`, in `tokens`' palette; nil without a pick.
    public func rgb(forKey key: String, tokens: ThemeTokens) -> ThemeRGB? {
        switch picks[key] {
        case .accent(let accent)?: AgentPresenceColor.rgb(of: accent, tokens: tokens)
        case .rgb(let rgb)?: rgb
        case nil: nil
        }
    }
}
