import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
@testable import CmuxNextDaemon
import CmuxNextTestSupport
import Foundation
import Testing

/// a1298 and a1244, Nov 21: on a fresh install the Chief page was blank in about 5 of 8 launches (fleet captures of
/// tour:chief-onboarding-meet), and HomePendingTerminalFocusTests timed out with "Home's dock pane shows nil". At
/// launch Home's page tab moves from the pane its workspace opened with into the new dock pane, and for a few frames
/// both panes list it. Each show took the one page view from the other pane (the ledger's displacement); when the old
/// pane showed it last and was then removed, nothing showed it again in the dock pane, which kept the tab selected
/// and drew nothing (`debug.surfaces`: `blank_reason not_shown`, no shown tab, no content).
@MainActor @Suite(.serialized, .closesItsWindows)
struct HomeDockShowsItsPageTests {
    typealias Fixture = SidebarMultiViewWindowTests.Fixture
    static let page = SurfaceID(rawValue: 901)
    /// Home's one pane (`ChiefPanelWindowTests.pageTree()`): the dock pane that stays.
    static let dock = PaneID(rawValue: 900)

    /// The pane that showed Home's page last and goes (the pane Home's workspace opened with).
    @MainActor final class OldPane: SurfacePresenter {
        func surfaceWasDisplaced(_ key: String) {}
        func surfaceIsFree(_ key: String) {}
    }

    /// The pane controller of daemon pane `id` in the window's shown workspace.
    static func pane(_ f: Fixture, _ id: PaneID) -> PaneController? {
        f.controller.content?.panes.values.first { $0.pane.handle == id }
    }

    /// Home's page view as pane `id` shows it: in that pane, in the window; nil when the pane shows nothing.
    static func shownPage(_ f: Fixture, _ id: PaneID) -> InternalPageView? {
        guard let pane = pane(f, id), case .page(let view)? = pane.currentContent, pane.view.content === view,
              view.window === f.controller.window else { return nil }
        return view
    }

    static func line(_ f: Fixture, _ id: PaneID) -> String {
        guard let pane = pane(f, id) else { return "no pane \(id)" }
        return "pane \(id): selected \(pane.stripModel.selectedID?.rawValue ?? "-"), shown \(pane.currentTabKey ?? "-"), "
            + "content \(pane.currentContent.map { "\($0.kind)" } ?? "nil")"
    }

    /// The ledger offers a key back to the pane it was taken from once the taker lets it go: when the taker goes, and
    /// when it shows another tab; never to a pane that went, and never while another pane holds the key.
    @Test func aTakenKeyIsOfferedBackWhenItsTakerLetsItGo() {
        var ledger = SurfaceLedger<String, Int>(capacity: 8)
        _ = ledger.present("home", by: 1, presence: .visible)
        let taken = ledger.present("home", by: 2, presence: .visible)
        #expect(taken.displaced == [.init(key: "home", owner: 1)] && taken.freed.isEmpty)
        let gone = ledger.removeOwner(2)
        #expect(gone.freed == [.init(key: "home", owner: 1)], "the pane that stays was not told: \(gone.freed)")
        #expect(ledger.removeOwner(1).freed.isEmpty)

        _ = ledger.present("home", by: 3, presence: .visible)
        _ = ledger.present("home", by: 4, presence: .visible)
        #expect(ledger.withdraw("home", by: 4).freed == [.init(key: "home", owner: 3)], "a taker that showed another tab offered nothing")
        _ = ledger.present("home", by: 3, presence: .visible)
        #expect(ledger.withdraw("home", by: 3).freed.isEmpty, "the key was offered to the pane that just let it go")

        _ = ledger.present("chat", by: 5, presence: .visible)
        _ = ledger.present("chat", by: 6, presence: .visible)
        _ = ledger.removeOwner(5)
        #expect(ledger.removeOwner(6).freed.isEmpty, "the key was offered to a pane that went")
    }

    /// The dock move as the launch makes it: the old pane shows Home's page last, taking its view from the dock pane,
    /// then goes. The dock pane shows Home's page.
    @Test func theDockPaneShowsHomesPageWhenTheOldPaneGoes() async throws {
        let f = try await Fixture(keys: ChiefPanelWindowTests.keys, tree: ChiefPanelWindowTests.pageTree())
        defer { f.close() }
        // Home's page provider, as the app registers it at launch (AppActions+Workspaces).
        f.services.pages.register(HomeDockTab(services: f.services))
        f.services.windows.show(workspaceID: "k2", in: f.state, from: .thisWindow)
        f.frame()
        f.services.windows.show(workspaceID: "k0", in: f.state, from: .thisWindow)
        f.frame()
        try #require(Self.shownPage(f, Self.dock) != nil, "Home's pane does not show its page: \(Self.line(f, Self.dock))")
        let key = try #require(Self.pane(f, Self.dock)?.currentTabKey)

        let old = OldPane()
        f.services.cache.present(key, by: old, presence: .visible)
        f.frame()
        #expect(Self.shownPage(f, Self.dock) == nil, "the old pane's show did not take Home's page from the dock pane")
        f.services.cache.removePresenter(old)
        for _ in 0..<10 where Self.shownPage(f, Self.dock) == nil {
            f.frame()
            try await Task.sleep(for: .milliseconds(20)) // test harness: a few display frames for the presentation scheduler
        }
        #expect(Self.shownPage(f, Self.dock) != nil, "the dock pane shows nothing after the old pane went: \(Self.line(f, Self.dock))")
    }
}
