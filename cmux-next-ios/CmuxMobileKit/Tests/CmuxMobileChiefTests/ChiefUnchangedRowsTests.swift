import Foundation
import Testing
@testable import CmuxMobileChief
#if os(iOS)
import SwiftUI
import UIKit
#endif

/// Leo, 2026-11-18: "we draw the visible area, right?" The Chief's live details and Home's pinned
/// grid draw every row they hold, so each stays bounded by a named cap, and a change to one row
/// draws that row only (`ChiefLiveDetailRow.bodyCount`, `HomeTile.bodyCount`: DEBUG test hooks).
@MainActor @Suite(.serialized) struct ChiefUnchangedRowsTests {
    /// A run of any length shows at most `detailCap` details, still-streaming thoughts included
    /// (they were added past the cap, one per open thought).
    @Test(arguments: [1_000, 10_000])
    func liveDetailsStayCappedAtAnyRunLength(n: Int) throws {
        var state = ChiefLiveState(conversation: "c")
        let tools: [[String: Any]] = (0..<n).map { ["id": "tool:\($0)", "kind": "tool", "tool": ["name": "Read"], "status": "done"] }
        _ = state.runChanged(["conversation": "c", "run": ["id": "r", "author": "a", "status": "running"], "steps": tools])
        // The owner's buffer with n thoughts still streaming (one frame: `delta` per thought copies the run).
        let thoughts: [[String: Any]] = (0..<n).map { ["step": "thought:\($0)", "seq": 0, "kind": "thought", "text": "thinking \($0)"] }
        _ = state.snapshot(["conversation": "c", "runs": [["run": "r", "author": "a", "steps": thoughts]]])
        let live = try #require(state.current)
        #expect(ChiefLiveState.detailCap <= 100)
        #expect(live.details.count == ChiefLiveState.detailCap, "showed \(live.details.count) details for \(n) steps")
        #expect(live.details.last?.id == "thought:\(n - 1)", "the newest detail is not the last one shown")
    }

    #if os(iOS)
    func settle(_ window: UIWindow) async {
        for _ in 0 ..< 5 {
            window.rootViewController?.view.layoutIfNeeded()
            try? await Task.sleep(for: .milliseconds(16))
        }
    }

    func details(_ range: Range<Int>) -> [ChiefLive.Detail] {
        range.map { ChiefLive.Detail(id: "tool:\($0)", kind: .tool, title: "Read file \($0)", text: "") }
    }

    /// A new detail (the oldest leaves at the cap) draws one row, not all 64.
    @Test func aNewLiveDetailDrawsOneRow() async {
        let cap = ChiefLiveState.detailCap
        let host = UIHostingController(rootView: ChiefLiveDetails(details: details(0..<cap)))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        await settle(window)
        #expect(ChiefLiveDetailRow.bodyCount >= cap, "the details never drew")
        ChiefLiveDetailRow.bodyCount = 0
        host.rootView = ChiefLiveDetails(details: details(1..<cap + 1))
        await settle(window)
        print("VISIBLE_ONLY chief_live_details rows=\(cap) row_bodies_after_one_new=\(ChiefLiveDetailRow.bodyCount)")
        #expect(ChiefLiveDetailRow.bodyCount <= 2, "one new detail drew \(ChiefLiveDetailRow.bodyCount) rows")
    }

    func tiles(working: Int?) -> [HomeTile] {
        (0..<9).map { index in
            HomeTile(id: "c\(index)", route: .mac(MacConversationRoute(conversationID: "c\(index)", chief: nil, title: "Pin \(index)")),
                     avatar: "P\(index)", name: "Pin \(index)", detail: nil, unread: false, working: index == working,
                     bubble: nil, muted: false, identifier: "home.pin.c\(index)", open: {}, menu: nil)
        }
    }

    /// One pin starts typing: its tile draws, the other eight do not (Home rebuilds every tile,
    /// with fresh tap closures, each time its list changes).
    @Test func onePinChangingDrawsOneTile() async {
        let host = UIHostingController(rootView: HomePinGrid(tiles: tiles(working: nil)))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        await settle(window)
        #expect(HomeTile.bodyCount >= 9, "the grid never drew")
        HomeTile.bodyCount = 0
        host.rootView = HomePinGrid(tiles: tiles(working: 4))
        await settle(window)
        print("VISIBLE_ONLY home_pin_grid tiles=9 tile_bodies_after_one_change=\(HomeTile.bodyCount)")
        #expect(HomeTile.bodyCount <= 2, "one pin's change drew \(HomeTile.bodyCount) tiles")
    }
    #endif
}
