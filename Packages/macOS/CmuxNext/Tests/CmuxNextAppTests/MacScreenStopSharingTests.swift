@testable import CmuxNextActions
@testable import CmuxNextMacScreen
import CmuxNextWakeups
import Foundation
import Testing

/// Stop Sharing This Mac (`macScreen.stopSharing`) is the one row that ends this Mac's session, wherever it is
/// hosted: the app's own host, or cmux Remote's worker in a build that bundles cmux Remote. Before, the worker's
/// session had its own row (cmux Remote: End Screen Sharing Session), and this row read "no device" there.
@MainActor @Suite(.serialized)
struct MacScreenStopSharingTests {
    private func actions(worker: MacScreenWorkerSession) -> (MacScreenActions, MacScreenPages) {
        let file = FileManager.default.temporaryDirectory.appending(path: "stop-sharing-\(UUID().uuidString)/mac-screen.json")
        let pages = MacScreenPages(store: MacScreenStore(file: file), work: BackgroundWork())
        let actions = MacScreenActions(pages: pages, selectedTab: { nil }, providerKey: { id, _ in id },
                                       open: { _, _, _ in }, refusal: { _ in }, worker: worker)
        return (actions, pages)
    }

    @Test func withoutAWorkerOrASessionItSaysNoDeviceIsConnected() throws {
        let (actions, pages) = actions(worker: .none)
        let reason = try #require(pages.hubHost.noSessionReason)
        #expect(actions.stopSharingUnavailable == reason)
        guard case let .refused(refusal, _) = actions.stopSharing().kind else {
            Issue.record("expected a refusal")
            return
        }
        #expect(refusal == reason)
    }

    @Test func aRunningWorkerEndsTheSessionItHosts() async throws {
        var stops = 0
        let (actions, pages) = actions(worker: MacScreenWorkerSession(running: { true }, stop: { stops += 1 }))
        #expect(pages.hubHost.noSessionReason != nil, "the app's own host has no session")
        #expect(actions.stopSharingUnavailable == nil)
        guard case let .waiting(wait, work) = actions.stopSharing().kind else {
            Issue.record("expected the worker's stop")
            return
        }
        #expect(wait == .externalProcess)
        #expect(await work() == nil)
        #expect(stops == 1)
    }

    @Test func aWorkerThatFailsSaysWhy() async throws {
        struct Refused: Error {}
        let (actions, _) = actions(worker: MacScreenWorkerSession(running: { true }, stop: { throw Refused() }))
        guard case let .waiting(_, work) = actions.stopSharing().kind else {
            Issue.record("expected the worker's stop")
            return
        }
        #expect(await work() != nil)
    }
}
