@testable import CmuxHomeCore
@testable import CmuxNextApp
import Testing

/// A conversation tab's view opens its conversation through its binding
/// and closes it when the view goes away (round-5 review, major 2). A tab
/// closed before the open ran used to close nothing and then open for
/// good: the viewer count, the cloud subscription and an "open" inbox row
/// stayed.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct HomeHostViewOpenCloseTests {
    /// Waits for the open's first page read (the store's load of `id`), a
    /// signal instead of yields: a busy test run holds the main actor long
    /// enough that 500 yields passed the time limit.
    static func firstPageRead(_ store: HomeStore, _ id: ConversationID) async {
        while let load = store.loads[id] { await load.value }
    }

    @Test func aTabClosedBeforeItsOpenRanLeavesTheConversationClosed() async {
        let services = AppServices(environment: AppEnvironment.current([:]))
        let store = services.home.homeStore
        let id = ConversationID("conv_tab_closed_early")
        do {
            let view = HomeHostView(services: services, conversation: id.rawValue)
            withExtendedLifetime(view) {}
        }
        // The open's first page read ran to its end.
        await Self.firstPageRead(store, id)
        #expect(store.viewers[id] == nil, "the open ran after the view went away and was never closed")
    }

    @Test func aTabOpenWhileItsViewLivesClosesWhenTheViewGoes() async {
        let services = AppServices(environment: AppEnvironment.current([:]))
        let store = services.home.homeStore
        let id = ConversationID("conv_tab_open")
        var view: HomeHostView? = HomeHostView(services: services, conversation: id.rawValue)
        await Self.firstPageRead(store, id)
        #expect(store.viewers[id] == 1)
        withExtendedLifetime(view) {}
        view = nil
        #expect(store.viewers[id] == nil)
    }
}
