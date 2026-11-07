import AppKit
import CmuxHomeCore
import CmuxNextHome
@testable import CmuxNextApp
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
        let value = [HomeChiefRosterTests.ada: Seq(42)].pageHidden
        #expect(value == .object(["hidden": .object(["conv_ada": .number(42)])]))
        #expect(([ConversationID: Seq]()).pageHidden == .object(["hidden": .object([:])]))
    }

    /// F5: a Home pane tab's content is this view; the focus model finds its page through
    /// ``PageWebViewContainer`` (``PageWebView/shown(in:)``), else the tab focuses a wrapper that takes no keys.
    @Test func theMessagesPageNamesItsPageToTheFocusModel() {
        #expect((HomeMessagesPage.self as Any) is any PageWebViewContainer.Type)
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
