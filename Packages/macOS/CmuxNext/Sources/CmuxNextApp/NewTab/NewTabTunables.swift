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

nonisolated enum NewTabTunables {
    static let layout = Tunable<NewTabLayoutChoice>.choice(
        "newTab.layout", .tabs, "New tab design",
        help: "Prototype design of the new tab screen. Applies to the next new tab.",
        default: .b, code: "NewTabTunables.layout")

    static var all: [TunableDescriptor] { [layout.descriptor] }
}
