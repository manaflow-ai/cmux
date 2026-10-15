import CmuxNextAgentPane
import CmuxNextDesign

/// The new tab design prototypes (Debug Settings `newTab.layout`, DEV and
/// NIGHTLY only; Release always shows B). A is deleted once B passes
/// dogfood (plans/cmux-next/new-tab.md, decision Q6).
nonisolated enum NewTabLayoutChoice: String, Sendable, CaseIterable, TunableChoice {
    case b, a

    var tunableTitle: String {
        switch self {
        case .b: "B: Search | Ask field, agent rows, chat cards"
        case .a: "A: Terminal | Browser | Agent switch"
        }
    }

    var pageLayout: AgentPaneNewTabLayout { self == .a ? .a : .b }
}

/// The New Tab page's style switch looks (webviews newtab/templates.ts STYLE_SWITCHES). Round is
/// the page's own look (#20473); the others are opt-in in Debug Settings (Lawrence 2026-10-14: no
/// Labs; a look moves to Settings once it earns it).
nonisolated enum NewTabStyleSwitchChoice: String, Sendable, CaseIterable, TunableChoice {
    case round, hint, dots, strip, names

    var tunableTitle: String {
        switch self {
        case .round: "Round dots (#20473)"
        case .hint: "Dots that name a pick"
        case .dots: "Chip dots (before #20127)"
        case .strip: "Layout sketches"
        case .names: "Style names (#20336)"
        }
    }
}

nonisolated enum NewTabTunables {
    static let layout = Tunable<NewTabLayoutChoice>.choice(
        "newTab.layout", .tabs, "New tab design",
        help: "Prototype design of the new tab screen. Applies to the next new tab.",
        default: .b, code: "NewTabTunables.layout")

    /// The page draws round for no override, so only an override is sent (`AgentPaneNewTab.styleSwitch`).
    static let styleSwitch = Tunable<NewTabStyleSwitchChoice>.choice(
        "newTab.styleSwitch", .tabs, "New tab style switch",
        help: "How the New Tab page shows its styles. Applies to the next new tab.",
        default: .round, code: "NewTabTunables.styleSwitch")

    static var all: [TunableDescriptor] { [layout.descriptor, styleSwitch.descriptor] }
}
