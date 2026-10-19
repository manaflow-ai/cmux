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

    /// The widget view under the New Tab composer (Leo 2026-10-18): a Projects card (this Mac
    /// and its recent projects) and a Needs you card (chats waiting on the user or that hit an
    /// error, each dismissable). Off by default: the default page stays calm.
    static let widgets = Tunable<Bool>.toggle(
        "newTab.widgets", .tabs, "New tab widgets",
        help: "Cards under the New Tab composer: this Mac's recent projects, and the chats that need you. Applies to the next new tab.",
        default: false, code: "NewTabTunables.widgets")

    static var all: [TunableDescriptor] { [layout.descriptor, widgets.descriptor] }
}
