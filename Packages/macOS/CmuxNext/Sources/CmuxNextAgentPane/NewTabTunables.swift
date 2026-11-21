public import CmuxNextDesign
public import CmuxNextDesignTokens

/// The new tab design prototypes (Debug Settings `newTab.layout`, DEV and
/// NIGHTLY only; Release always shows B). A is deleted once B passes
/// dogfood (plans/cmux-next/new-tab.md, decision Q6).
public nonisolated enum NewTabLayoutChoice: String, Sendable, CaseIterable, TunableChoice {
    case b, a

    public var tunableTitle: String {
        switch self {
        case .b: "B: Search | Ask field, agent rows, chat cards"
        case .a: "A: Terminal | Browser | Agent switch"
        }
    }

    public var pageLayout: AgentPaneNewTabLayout { self == .a ? .a : .b }
}

/// Debug Settings declarations of the New Tab page.
public nonisolated struct NewTabTunables {
    public nonisolated init() {}
    public static let layout = Tunable<NewTabLayoutChoice>.choice(
        "newTab.layout", .tabs, "New tab design",
        help: "Prototype design of the new tab screen. Applies to the next new tab.",
        default: .b, code: "NewTabTunables.layout")

    public static var all: [TunableDescriptor] { [layout.descriptor] }
}
