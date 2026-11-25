#if os(iOS)
import Testing
@testable import CmuxMobileLive

/// Leo, 2026-11-21: "i lost connection with cosmic gray or some s***... multiple issues to fix there".
/// A chat's transcript store (scroll place, follow-the-end state) is rebuilt only when the Mac
/// names a different session, not when a reconnect's partial resync lists the tab with none.
@Suite struct ReconnectKeepsChatStoreTests {
    @Test func aTabMissingFromOnePublishKeepsItsStore() {
        #expect(!LiveCoordinator.chatSessionChanged(built: "s-1", listed: nil))
    }

    @Test func theSameSessionKeepsItsStore() {
        #expect(!LiveCoordinator.chatSessionChanged(built: "s-1", listed: "s-1"))
    }

    @Test func aNewSessionRebuildsTheStore() {
        #expect(LiveCoordinator.chatSessionChanged(built: "s-1", listed: "s-2"))
    }

    @Test func aChatThatGainedASessionRebuildsOnIt() {
        #expect(LiveCoordinator.chatSessionChanged(built: nil, listed: "s-1"))
        #expect(!LiveCoordinator.chatSessionChanged(built: nil, listed: nil))
    }
}
#endif
