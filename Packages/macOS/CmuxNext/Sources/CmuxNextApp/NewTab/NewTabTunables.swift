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

    /// Off until the switcher is styled (cx-7qqu); the saved template applies either way.
    static let templateSwitcher = Tunable<Bool>.toggle(
        "newTab.templateSwitcher", .tabs, "New tab template switcher",
        help: "Shows the template dots that switch the new tab page in place. Applies to the next new tab.",
        default: false, code: "NewTabTunables.templateSwitcher")

    static var all: [TunableDescriptor] { [layout.descriptor, templateSwitcher.descriptor] }
}
