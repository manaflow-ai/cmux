#if os(iOS)
import SwiftUI
import Testing
import UIKit
@testable import CmuxMobileAgentChat

/// Leo, 2026-11-23: "ios, bottom of the agent transcript, i scroll a bit up then down. it
/// jumps at the bottom." Following the newest row used to mean being within 80 pt of it, so a
/// reader resting a bit above the bottom still followed, and the next layout pass (a row
/// measured, a streamed line, the stack settling) cut the offset to the bottom under them.
/// Following now means resting on the newest row; a reader a bit above it stays put.
@MainActor
@Suite(.serialized) struct BottomScrollJumpTests {
    struct Transcript {
        let controller: ChatTranscriptController
        let store: AgentChatStore
        let surface: AgentChatSurface
        let scroll: UIScrollView
        let window: UIWindow
        var bottomY: CGFloat { scroll.contentSize.height + scroll.contentInset.bottom - scroll.bounds.height }

        func settle() {
            for _ in 0 ..< 5 {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
                controller.view.layoutIfNeeded()
            }
        }
    }

    /// A long transcript resting on its newest turn.
    func transcript() throws -> Transcript {
        let store = AgentChatStore(source: SmoothChatTests.Silent())
        store.nextFrame = nil
        store.apply(.batch((0..<60).flatMap { SmoothChatTests.turn($0) }))
        let surface = AgentChatSurface()
        let controller = ChatTranscriptController(
            placement: .owned, surface: surface, store: store,
            empty: AnyView(EmptyView()), dock: AnyView(Color.clear.frame(height: 96)), jump: nil
        )
        controller.reducesMotion = { true }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        let scroll = try #require(controller.view.subviews.lazy.compactMap { $0 as? ChatTranscriptCollectionView }.first)
        for _ in 0 ..< 100 where scroll.contentSize.height < 4000 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            controller.view.layoutIfNeeded()
        }
        try #require(scroll.contentSize.height >= 4000, "content measured \(scroll.contentSize.height)")
        controller.scrollTranscript(toTop: false, animated: false)
        let transcript = Transcript(controller: controller, store: store, surface: surface, scroll: scroll, window: window)
        transcript.settle()
        #expect(surface.following)
        #expect(abs(scroll.contentOffset.y - transcript.bottomY) < 1, "rests on the newest turn")
        return transcript
    }

    @Test func aReaderABitAboveTheBottomIsNotPulledDownByTheNextLayout() throws {
        let transcript = try transcript()
        defer { transcript.window.isHidden = true }
        // Scrolled a bit up (well inside the old 80 pt band), at rest.
        let resting = transcript.bottomY - 50
        transcript.scroll.contentOffset.y = resting
        transcript.settle()
        #expect(!transcript.surface.following, "50 pt above the newest turn is not following it")
        // A turn streams in: the list lays out and measures it.
        transcript.store.apply(.batch(SmoothChatTests.turn(60)))
        transcript.settle()
        #expect(abs(transcript.scroll.contentOffset.y - resting) < 1,
                "the reader stays where they rested: \(resting) -> \(transcript.scroll.contentOffset.y)")
    }

    @Test func backOnTheNewestTurnTheTranscriptFollowsAgain() throws {
        let transcript = try transcript()
        defer { transcript.window.isHidden = true }
        transcript.scroll.contentOffset.y = transcript.bottomY - 50
        transcript.settle()
        transcript.scroll.contentOffset.y = transcript.bottomY
        transcript.settle()
        #expect(transcript.surface.following)
        transcript.store.apply(.batch(SmoothChatTests.turn(60)))
        transcript.settle()
        #expect(abs(transcript.scroll.contentOffset.y - transcript.bottomY) < 1, "follows the new turn to the bottom")
    }
}
#endif
