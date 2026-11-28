import CmuxMobileModel
import Foundation
import Testing
@testable import CmuxMobileWorkspaces

#if os(iOS)
import CmuxMobileAgentChat
import CmuxMobileLinkFFI
import CmuxTabsKit

/// Leo, 2026-11-23: "we want a ... filtering mechanism for only agent sessions, agent
/// sessions/terminals, and ... browsers on their own honestly should be a ... toggle."
/// The overview's tabs follow the pane filter. The default is agent sessions and terminals with
/// browsers shown, and the toggle can narrow the view (Leo's ask, 2026-11-26).
/// `ws-cmux` (mock) lists t-claude (agent), t-zsh (terminal), t-docs (browser).
@MainActor @Suite(.serialized) struct PaneFilterTests {
    static let everything = PaneFilter(scope: .agentsAndTerminals, showBrowsers: true)

    static func rig(_ filter: PaneFilter? = nil, active: String = "t-claude") -> (WorkspaceTabsSource, PaneFilterSetting) {
        let store = AppStore.mock(tabMemory: .inMemory([:]))
        store.macConnection["mac-studio"] = .connected
        let source = WorkspaceTabsSource(store: store, workspaceID: "ws-cmux", sessions: AgentSessionDirectory(), clock: GridTestClock())
        let setting = PaneFilterSetting(defaults: nil)
        if let filter { setting.filter = filter }
        source.paneFilter = setting
        source.opened()
        source.activate(active)
        return (source, setting)
    }

    @Test func theDefaultShowsBrowsersAndCanHideThem() {
        let (source, setting) = Self.rig()
        #expect(!setting.isChanged)
        #expect(source.tabs.map(\.id) == ["t-claude", "t-zsh", "t-docs"])
        #expect(source.paneFilterResult.hiddenBrowsers == 0)
        setting.showsBrowsers = false
        #expect(setting.isChanged)
        #expect(source.tabs.map(\.id) == ["t-claude", "t-zsh"])
        #expect(source.paneFilterResult.hiddenBrowsers == 1)
    }

    /// The overview owner's warning: card pictures are kept per tab id, so a tab the filter hides
    /// keeps its entry (and its picture) and comes back drawn when the filter clears.
    @Test func aHiddenTabKeepsItsCard() {
        let (source, setting) = Self.rig(PaneFilter(scope: .agentsAndTerminals, showBrowsers: false))
        #expect(!source.tabs.map(\.id).contains("t-docs"))
        let entry = try? #require(source.entry("t-docs"))
        setting.showsBrowsers = true
        #expect(source.entry("t-docs") === entry)
    }

    @Test func agentsOnlyShowsAgentSessions() {
        let (source, _) = Self.rig(PaneFilter(scope: .agents, showBrowsers: false))
        #expect(source.tabs.map(\.id) == ["t-claude"])
        #expect(source.paneFilterResult.hiddenTerminals == 1)
        #expect(source.paneFilterResult.hiddenBrowsers == 1)
    }

    @Test func agentsAndTerminalsTucksBrowsersAway() {
        let (source, _) = Self.rig(PaneFilter(scope: .agentsAndTerminals, showBrowsers: false))
        #expect(source.tabs.map(\.id) == ["t-claude", "t-zsh"])
    }

    @Test func theBrowserToggleStandsOnItsOwn() {
        let (source, _) = Self.rig(PaneFilter(scope: .agents, showBrowsers: true))
        #expect(source.tabs.map(\.id) == ["t-claude", "t-docs"])
    }

    /// A tab the filter hides that is on screen (opened from a notification or Search) still
    /// has its card, so the grid zooms out of it; its neighbours stay hidden.
    @Test func theTabOnScreenAlwaysShows() {
        let (source, _) = Self.rig(PaneFilter(scope: .agents, showBrowsers: false), active: "t-docs")
        #expect(source.activeTabID == "t-docs")
        #expect(source.tabs.map(\.id) == ["t-claude", "t-docs"])
    }

    @Test func changingTheFilterChangesTheTabsAtOnce() {
        let (source, setting) = Self.rig(Self.everything)
        #expect(source.tabs.count == 3)
        setting.scope = .agents
        #expect(source.tabs.map(\.id) == ["t-claude", "t-docs"])
        setting.showsBrowsers = false
        #expect(source.tabs.map(\.id) == ["t-claude"])
        setting.filter = paneFilterDefault()
        #expect(source.tabs.map(\.id) == ["t-claude", "t-zsh", "t-docs"])
    }

    @Test func theChoiceIsKeptAcrossLaunches() throws {
        let suite = "PaneFilterTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = PaneFilterSetting(defaults: defaults)
        #expect(first.filter == paneFilterDefault())
        #expect(first.showsBrowsers)
        first.filter = PaneFilter(scope: .agentsAndTerminals, showBrowsers: false)
        let reloaded = PaneFilterSetting(defaults: defaults)
        #expect(reloaded.filter == PaneFilter(scope: .agentsAndTerminals, showBrowsers: false))
        #expect(!reloaded.showsBrowsers)
        reloaded.filter = PaneFilter(scope: .agents, showBrowsers: true)
        #expect(PaneFilterSetting(defaults: defaults).filter == PaneFilter(scope: .agents, showBrowsers: true))
        defaults.set("from-a-newer-build", forKey: PaneFilterSetting.key)
        #expect(PaneFilterSetting(defaults: defaults).filter == paneFilterDefault())
    }

    /// A drag in a filtered grid lands where it shows: grid slot 1 is t-docs (t-zsh is hidden),
    /// so the Mac index is t-docs's, 2.
    @Test func aDropInAFilteredGridTakesTheShownTabsPlace() throws {
        let (source, _) = Self.rig(PaneFilter(scope: .agents, showBrowsers: true))
        let workspace = try #require(source.workspace)
        #expect(source.workspaceIndex(forGridIndex: 0, in: workspace) == 0)
        #expect(source.workspaceIndex(forGridIndex: 1, in: workspace) == 2)
        #expect(source.workspaceIndex(forGridIndex: 9, in: workspace) == 2)
        let (all, _) = Self.rig(Self.everything)
        #expect(all.workspaceIndex(forGridIndex: 1, in: workspace) == 1)
    }

    // MARK: Agent card pictures at the grid's card size

    /// An agent card's picture was drawn at a fixed two-column card's size: on an unfolded
    /// screen's three-column grid it was drawn 50% too large, and a lone card on a wide page
    /// ignored TabsKit's 300 pt cap. Now it is TabsKit's own card width.
    @Test func agentCardsDrawAtTheGridsColumnWidth() {
        let (source, _) = Self.rig(Self.everything)
        source.rememberPageSize(CGSize(width: 669, height: 951))
        source.overviewColumns = 3
        let three = TabsKitOverviewGeometry.cardWidth(pageWidth: 669, columns: 3, cards: 3)
        #expect(abs(source.cardScale - three / 669) < 0.0001)
        #expect(three < (669 - 48) / 2)
        source.rememberPageSize(CGSize(width: 402, height: 874))
        source.overviewColumns = 2
        #expect(abs(source.cardScale - 177.0 / 402) < 0.0001)
    }

    @Test func aLoneFilteredCardDrawsAtTheLoneCardsSize() {
        let (source, _) = Self.rig(PaneFilter(scope: .agents, showBrowsers: false))
        source.rememberPageSize(CGSize(width: 669, height: 951))
        source.overviewColumns = 3
        #expect(source.tabs.count == 1)
        // TabsKit's lone card: two thirds of the page, at most 300 pt.
        #expect(abs(source.cardScale - 300.0 / 669) < 0.0001)
    }
}
#endif
