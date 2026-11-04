@testable import CmuxHomeCore
import Foundation
@testable import MessagesLabHome
import Testing

/// The Mac Chief chat (the Home transcript over HomeStore), open and resting at the newest
/// message, keeps its loaded window bounded while replies keep arriving: nobody scrolls a
/// Chief chat left open, so the bound must not wait for a scroll.
@Suite(.serialized) @MainActor struct HomeWindowBoundTests {
    /// The bound the Home transcript keeps (HomeStore.windowTrimThreshold),
    /// as numbers so this test also builds, and fails, on a commit without the bound.
    static let trimThreshold = 1500
    static let batches = 32
    static let perBatch = 50

    /// The regression: 1,600 replies to an open chat leave at most the trim threshold loaded.
    @Test func liveRepliesWhileRestingAtTheNewestKeepTheWindowBounded() async throws {
        let rig = try await HomeChatRig()
        defer { rig.stop() }
        let last = try await flood(rig) { _, _ in }
        let loaded = rig.store.transcript(for: HomeChatRig.conversation).count
        #expect(loaded <= Self.trimThreshold, "loaded \(loaded) after \(last) replies")
        #expect(rig.store.transcript(for: HomeChatRig.conversation).last?.plainText == last)
        #expect(rig.view.controller.store?.state.ui.scroll.pinnedToBottom == true)
    }

    /// Posts the replies in batches; after each, two display frames (the arrival, then the
    /// bound the view schedules for the next frame). Returns the newest reply's text.
    private func flood(_ rig: HomeChatRig, each: (Int, Int) -> Void) async throws -> String {
        var text = ""
        var arrived = 0
        for batch in 1...Self.batches {
            for _ in 0..<Self.perBatch {
                arrived += 1
                text = "\(arrived). Chief: the fleet build passed and the tag is published."
                #expect(await rig.source.post(text, from: rig.chief, in: HomeChatRig.conversation, key: .make()) != nil)
            }
            let newest = text
            await HomeChatRig.until { rig.store.transcript(for: HomeChatRig.conversation).last?.plainText == newest }
            rig.frame()
            rig.frame()
            let loaded = rig.store.transcript(for: HomeChatRig.conversation).count
            print("CHIEF_WINDOW_MAC batch=\(batch) arrived=\(arrived) loaded=\(loaded)")
            each(arrived, loaded)
        }
        return text
    }
}
