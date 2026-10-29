public import CmuxTheme

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
        if let accent = GroupColor(rawValue: value), GroupColor.presenceOrder.contains(accent) { return .accent(accent) }
        guard value.count == 7, value.first == "#", let rgb = ThemeRGB(cssHex: value) else { return nil }
        return .rgb(rgb)
    }
}
