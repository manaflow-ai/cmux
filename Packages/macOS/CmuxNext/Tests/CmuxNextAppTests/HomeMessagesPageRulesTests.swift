import AppKit
import CmuxHomeCore
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextHome
import CmuxNextHostedChief
import CmuxNextPages
import Testing

/// What the React Messages page's host decides (review of cmux#37736 at c3dd70eb): New Message
/// stays open while the page reports no conversation (F1), the first load opens the preferred
/// Chief by the same rule as later ones (C1), Delete Conversation from List moves the page off the
/// deleted conversation (F4), and the page view is found by the focus model (F5).
@MainActor @Suite(.serialized)
struct HomeMessagesPageRulesTests {
    /// F1: New Message reports `conversation: null` with `composing`; the default conversation must
    /// not open over it (it would leave New Message at once).
    @Test func newMessageIsNeverReplacedByTheDefaultConversation() {
        let home = Self.home()
        let rows = HomeChiefDefaultTests.cloudLedRows
        let composing = HomeDefaultConversation.afterShown(nil, composing: true, followed: "conv_hosted", rows: rows, home: home)
        #expect(composing == .init(open: nil, followed: "conv_hosted"), "New Message stays, and what was followed stays followed")
        let empty = HomeDefaultConversation.afterShown(nil, composing: false, followed: nil, rows: rows, home: home)
        #expect(empty.open?.rawValue == "conv_hosted", "nothing shown and no New Message: the default opens, so the test above fails for its own reason")
    }

    /// C1: the first report (nothing open once the inbox is read) opens the preferred Chief and
    /// follows it, as a later Chief change would; a conversation the person opened stays theirs.
    @Test func theFirstLoadOpensThePreferredChiefAndFollowsIt() {
        let home = Self.home()
        let rows = HomeChiefDefaultTests.cloudLedRows
        let first = HomeDefaultConversation.afterShown(nil, composing: false, followed: nil, rows: rows, home: home)
        #expect(first == .init(open: CmuxHomeCore.ConversationID("conv_hosted"), followed: "conv_hosted"))
        // The page then reports the Chief it opened: still followed.
        #expect(HomeDefaultConversation.afterShown(CmuxHomeCore.ConversationID("conv_hosted"), composing: false, followed: first.followed,
                                                   rows: rows, home: home) == .init(open: nil, followed: "conv_hosted"))
        // The person opens a DM: no longer followed, and nothing opens.
        #expect(HomeDefaultConversation.afterShown(HomeChiefRosterTests.ada, composing: false, followed: "conv_hosted",
                                                   rows: rows, home: home) == .init(open: nil, followed: nil))
    }

    /// F4: leaving the shown conversation shows its neighbor, else the default conversation.
    @Test func deletingTheShownConversationMovesToItsNeighborElseTheDefault() {
        let home = Self.home()
        let rows = HomeChiefDefaultTests.cloudLedRows
        let local = HomeChiefRosterTests.local
        #expect(HomeDefaultConversation.replacement(leaving: HomeChiefRosterTests.ada, next: local, rows: rows, home: home) == local)
        #expect(HomeDefaultConversation.replacement(leaving: HomeChiefRosterTests.ada, next: nil, rows: rows, home: home)?.rawValue == "conv_hosted")
        #expect(HomeDefaultConversation.replacement(leaving: HomeChiefRosterTests.ada, next: HomeChiefRosterTests.ada, rows: rows, home: home)?.rawValue
            == "conv_hosted", "the conversation itself is no neighbor")
    }

    /// F4: the deleted set goes to the page as `{hidden: {id: seq}}`.
    @Test func theHiddenStreamSendsEachDeletedConversationWithItsSeq() {
        let value = HomeMessagesHostProvider.json(hidden: [HomeChiefRosterTests.ada: 42])
        #expect(value == .object(["hidden": .object(["conv_ada": .number(42)])]))
        #expect(HomeMessagesHostProvider.json(hidden: [:]) == .object(["hidden": .object([:])]))
    }

    /// F5: a Home pane tab's content is this view; the focus model finds its page through
    /// ``PageWebViewContainer`` (``PageWebView/shown(in:)``), else the tab focuses a wrapper that takes no keys.
    @Test func theMessagesPageNamesItsPageToTheFocusModel() {
        #expect((HomeMessagesPage.self as Any) is any PageWebViewContainer.Type)
    }

    /// Round 2 F3: New Message keeps the conversation open before it as the host's `shown`, so the
    /// dock's Messages to Channels switch (its fallback reads `shown`) hands that conversation on.
    @Test func newMessageKeepsTheConversationOpenBeforeIt() {
        let services = HomeChiefDefaultTests.services()
        Self.kept.append(services)
        let host = HomeMessagesHostProvider(services: services)
        var heard: [(CmuxHomeCore.ConversationID?, Bool)] = []
        host.onShown = { heard.append(($0, $1)) }
        host.reportShown(HomeChiefRosterTests.ada, composing: false)
        host.reportShown(nil, composing: true)
        #expect(host.shown == HomeChiefRosterTests.ada, "New Message is not 'nothing open'")
        #expect(host.page.composing)
        #expect(heard.last.map { $0.0 == HomeChiefRosterTests.ada && $0.1 } == true)
        host.reportShown(nil, composing: false)
        #expect(host.shown == nil, "New Message closed with nothing open: nothing is shown")
        #expect(!host.page.composing)
    }

    /// Round 2 F2: the drag strip takes the app's one titlebar path: it answers `.movesWindow` to
    /// ``TitlebarDragPolicy`` and its own mouse-down moves nothing (the window's `sendEvent` drags once).
    @Test func theDragStripLeavesTheDragToTheWindowsTitlebarPath() throws {
        let strip = HomeWindowDragStrip(frame: CGRect(x: 0, y: 0, width: 200, height: HomeWindowDragStrip.height))
        #expect(strip.titlebarPress(atWindowPoint: .zero) == .movesWindow)
        #expect(strip.mouseDownCanMoveWindow)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView?.addSubview(strip)
        let before = window.frame
        let press = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 10, y: 95), modifierFlags: [], timestamp: 0,
                                                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 2, pressure: 1))
        strip.mouseDown(with: press)
        #expect(window.frame == before, "a double-click on the strip itself zooms nothing: the window's path runs it once")
    }

    /// The suite's services: `HomeService` holds its services unowned, so they live for the run.
    static var kept: [AppServices] = []

    /// Auto with no local brain and a Hosted Chief: the Hosted Chief is the preferred one.
    static func home() -> HomeService {
        let services = HomeChiefDefaultTests.services()
        kept.append(services)
        services.home.setCloudChiefs(HomeCloudChiefs(hosted: HomeChiefDefaultTests.hosted, placed: HomeChiefDefaultTests.placed))
        services.home.localChiefRunning = false
        return services.home
    }
}
