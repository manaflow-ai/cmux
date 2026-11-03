public import CmuxNextDesign

/// How a palette row of an on/off command shows its current state (`palette.toggleStyle` in Debug
/// Settings). Lawrence 2026-11-03: "'toggle' options are very confusing, since we don't know the
/// current state." Every style reads the state live when the palette opens.
public nonisolated enum PaletteToggleStyle: String, Sendable, CaseIterable, TunableChoice {
    /// A mini switch at the row's trailing edge, accent-filled while on (default): the System
    /// Settings and Raycast cue, the same in every language.
    case trailingSwitch
    /// A switch at the trailing edge and the switch's state in words beside it ("On", "Off").
    case switchWithWord
    /// A small "On" or "Off" pill at the trailing edge.
    case wordPill
    /// A checkmark at the trailing edge while on, nothing while off (a menu's checked item).
    case trailingCheck
    /// The row's icon becomes a filled check while on (the look before this choice existed).
    case leadingCheck
    /// The title ends with the state: "Toggle Left Sidebar · On".
    case titleSuffix
    /// No state shown (the palette before 2026-11-03), for comparison.
    case none

    public var tunableTitle: String {
        switch self {
        case .trailingSwitch: "Trailing switch (default)"
        case .switchWithWord: "Trailing switch with On / Off"
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
        case .trailingSwitch, .switchWithWord, .wordPill, .trailingCheck: true
        case .leadingCheck, .titleSuffix, .none: false
        }
    }
}
