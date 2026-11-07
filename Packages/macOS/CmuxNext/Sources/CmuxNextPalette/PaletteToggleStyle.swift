public import CmuxNextDesign

/// How a palette row that flips a state shows it now (`palette.toggleStyle` in Debug Settings).
/// Lawrence 2026-11-03: "'toggle' options are very confusing, since we don't know the current
/// state." Leo 2026-11-07, on a Settings row reading "Off" beside a command row drawing a switch:
/// "if we're gonna do anything, we ought to, like, just unify." Every row that flips a state (a
/// catalog toggle such as Focus Ring and a Settings schema toggle alike) takes this one treatment,
/// read live when the palette builds its rows (``apply(title:symbol:isOn:)``). No style draws a
/// switch: the row itself is the control, and Return or a click flips it in place.
public nonisolated enum PaletteToggleStyle: String, Sendable, CaseIterable, TunableChoice {
    /// "On" in the accent's lit ink, "Off" in the tertiary ink, right-aligned in a column as wide
    /// as the wider word (default): the plain state text Settings rows showed, with On lit.
    case stateWord
    /// The same words, each after a small dot: filled with the accent while on, an outline while off.
    case stateWordDot
    /// The same column, with "Off" in the secondary ink, so an off row reads as clearly as an on one.
    case stateWordStrongOff
    /// A small "On" or "Off" pill at the trailing edge.
    case wordPill
    /// A checkmark at the trailing edge while on, nothing while off (a menu's checked item).
    case trailingCheck
    /// The row's icon becomes a filled check while on.
    case leadingCheck
    /// The title ends with the state: "Focus Ring · On".
    case titleSuffix
    /// No state shown (the palette before 2026-11-03), for comparison.
    case none

    public var tunableTitle: String {
        switch self {
        case .stateWord: "On / Off, On lit (default)"
        case .stateWordDot: "On / Off after a dot"
        case .stateWordStrongOff: "On / Off, Off in secondary ink"
        case .wordPill: "On / Off pill"
        case .trailingCheck: "Trailing checkmark while on"
        case .leadingCheck: "Icon becomes a check while on"
        case .titleSuffix: "Title ends with · On / · Off"
        case .none: "No state (before)"
        }
    }

    /// Whether the row's icon is replaced by a filled check while on.
    var replacesIcon: Bool { self == .leadingCheck }

    /// Whether the title carries the state.
    var suffixesTitle: Bool { self == .titleSuffix }

    /// Whether the trailing state badge draws.
    var drawsBadge: Bool {
        switch self {
        case .stateWord, .stateWordDot, .stateWordStrongOff, .wordPill, .trailingCheck: true
        case .leadingCheck, .titleSuffix, .none: false
        }
    }

    /// The title and icon a row that flips a state shows in this style, with `isOn` its state now
    /// (nil for a row that flips nothing). The one place both the command rows
    /// (``RegistryPaletteProvider``) and the Settings rows (``SettingsPaletteProvider``) decide them.
    func apply(title: String, symbol: String?, isOn: Bool?) -> (title: String, symbol: String?) {
        guard let isOn else { return (title, symbol) }
        return (suffixesTitle ? PaletteStrings.titleWithState(title, isOn ? PaletteStrings.on : PaletteStrings.off) : title,
                replacesIcon && isOn ? "checkmark.circle.fill" : symbol)
    }
}
