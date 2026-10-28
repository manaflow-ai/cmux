/// Who made an agent pane (``AgentPaneView/maker``): the report of a pane freed without ``AgentPaneView/close()``
/// names it (2026-10-28, handoff/cef-parent-tracker-crash.md). Fixed values: a crash key stores the raw value.
public nonisolated enum AgentPaneMaker: UInt64, Sendable, CaseIterable {
    /// Not set (a test, or a maker that does not say).
    case unknown = 0
    /// A tab's pane (`AgentTabStore.view(for:)`).
    case tab = 1
    /// A New Tab page made ahead of the tab (`AgentTabStore.makeSpare`).
    case spare = 2
    /// A chat outside any pane (`AgentTabStore.standaloneView`: onboarding, Start Agent).
    case standalone = 3
    /// Not an agent pane: an internal page tab's view (`InternalPageTabStore`: Settings, History, ...) freed with its
    /// page inside; the fault log names the page.
    case internalPage = 16

    /// The name in a fault log.
    public var name: String {
        switch self {
        case .unknown: "unknown"
        case .tab: "tab"
        case .spare: "spare"
        case .standalone: "standalone"
        case .internalPage: "internal_page"
        }
    }
}
