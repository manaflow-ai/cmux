#if os(iOS)
import SwiftUI
import Testing
import UIKit
@testable import CmuxMobileAgentChat

/// With Reduce Motion on, Jump to latest from far up a long transcript hid
/// the whole transcript, waited 50 ms, faded it back over 150 ms and sprang
/// the last screen over 400 ms. It now lands at once with the transcript
/// shown throughout. Without Reduce Motion the long jump keeps its cut,
/// its hidden frame (a stale tile drew over the composer) and its spring.
/// An animation writes the final model values at once, so each check reads
/// the layers' animations, not only the end point.
@MainActor
@Suite(.serialized) struct JumpReduceMotionTests {
    struct Transcript {
        let controller: ChatTranscriptController
        let scroll: UIScrollView
        /// The hosted transcript (the view the long jump hid).
        let content: UIView
        let window: UIWindow
        var bottomY: CGFloat { scroll.contentSize.height + scroll.contentInset.bottom - scroll.bounds.height }
        var moving: Bool {
            !(scroll.layer.animationKeys() ?? []).isEmpty || !(content.layer.animationKeys() ?? []).isEmpty
        }
    }

    /// A transcript many screens tall, read from its top.
    func transcript(reducesMotion: Bool) throws -> Transcript {
        let controller = ChatTranscriptController(
            placement: .owned, surface: AgentChatSurface(),
            content: AnyView(Color.gray.frame(height: 9000)), empty: AnyView(EmptyView()),
            dock: AnyView(Color.clear.frame(height: 96)), jump: nil
        )
        controller.reducesMotion = { reducesMotion }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        let scroll = try #require(controller.view.subviews.lazy.compactMap { $0 as? ChatTranscriptScrollView }.first)
        // SwiftUI reports the content's height on a later turn of the run loop.
        for _ in 0 ..< 100 where scroll.contentSize.height < 8000 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            controller.view.layoutIfNeeded()
        }
        try #require(scroll.contentSize.height >= 8000, "content measured \(scroll.contentSize.height)")
        let content = try #require(controller.children.first?.view)
        // Up at the first turn, no longer following the newest one.
        controller.scrollTranscript(toContentY: 0, animated: false)
        #expect(scroll.contentOffset.y < scroll.bounds.height)
        return Transcript(controller: controller, scroll: scroll, content: content, window: window)
    }

    @Test func aLongJumpLandsAtOnceWithTheTranscriptShown() throws {
        let transcript = try transcript(reducesMotion: true)
        defer { transcript.window.isHidden = true }
        transcript.controller.scrollTranscript(toTop: false, animated: true)
        #expect(!transcript.moving, "no fade and no spring")
        #expect(transcript.content.alpha == 1, "the transcript is never hidden")
        #expect(abs(transcript.scroll.contentOffset.y - transcript.bottomY) < 1, "lands on the newest turn")
    }

    /// The oracle sees motion: without Reduce Motion the long jump still
    /// fades the transcript back and springs to the bottom.
    @Test func withoutReduceMotionTheLongJumpStillAnimates() throws {
        let transcript = try transcript(reducesMotion: false)
        defer { transcript.window.isHidden = true }
        transcript.controller.scrollTranscript(toTop: false, animated: true)
        #expect(transcript.moving)
        #expect(abs(transcript.scroll.contentOffset.y - transcript.bottomY) < 1)
    }
}
#endif
