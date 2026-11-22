@testable import CmuxNextActions
@testable import CmuxNextMacScreen
import CmuxNextWakeups
import Foundation
import Testing

/// Stop Sharing This Mac (`macScreen.stopSharing`) is the one row that ends this Mac's session in the app's own host.
@MainActor @Suite(.serialized)
struct MacScreenStopSharingTests {
    private func actions() -> (MacScreenActions, MacScreenPages) {
        let file = FileManager.default.temporaryDirectory.appending(path: "stop-sharing-\(UUID().uuidString)/mac-screen.json")
        let pages = MacScreenPages(store: MacScreenStore(file: file), work: BackgroundWork())
        let actions = MacScreenActions(pages: pages, selectedTab: { nil }, providerKey: { id, _ in id },
                                       open: { _, _, _ in }, refusal: { _ in })
        return (actions, pages)
    }

    @Test func withoutASessionItSaysNoDeviceIsConnected() throws {
        let (actions, pages) = actions()
        let reason = try #require(pages.hubHost.noSessionReason)
        #expect(actions.stopSharingUnavailable == reason)
        guard case let .refused(refusal, _) = actions.stopSharing().kind else {
            Issue.record("expected a refusal")
            return
        }
        #expect(refusal == reason)
    }
}
