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
/// An animation writes the final model values at once, so the end point
/// is no proof: each check records every offset and opacity the jump wrote
/// on its way (the cut one screen short, the hidden transcript), and reads
/// the drawn frames after it.
@MainActor
@Suite(.serialized) struct JumpReduceMotionTests {
    @MainActor
    struct Transcript {
        let controller: ChatTranscriptController
        let scroll: UIScrollView
        /// The transcript's rows (the list's collection view; its opacity is read too).
        var content: UIView { scroll }
        let window: UIWindow
        var bottomY: CGFloat { scroll.contentSize.height + scroll.contentInset.bottom - scroll.bounds.height }
        /// What a jump wrote on its way: every scroll offset and every
        /// transcript opacity, in order.
        @MainActor
        final class Path {
            var offsets: [CGFloat] = []
            var opacities: [Float] = []
        }

        func jump() -> Path {
            let path = Path()
            let offsets = scroll.observe(\.contentOffset, options: [.new]) { _, change in
                MainActor.assumeIsolated { if let y = change.newValue?.y { path.offsets.append(y) } }
            }
            let opacities = content.layer.observe(\.opacity, options: [.new]) { _, change in
                MainActor.assumeIsolated { if let opacity = change.newValue { path.opacities.append(opacity) } }
            }
            // The long jump to the newest turn, through the same animated scroll
            // as Jump to latest. `toTop: false` resumes following first, and
            // the test host's next layout pass then snaps a following
            // transcript to the bottom before the scroll runs, which hides it.
            controller.scrollTranscript(toContentY: scroll.contentSize.height, animated: true)
            offsets.invalidate()
            opacities.invalidate()
            return path
        }

        /// An offset the jump passed through short of the bottom (the long
        /// jump's cut).
        func cut(_ path: Path) -> CGFloat? {
            path.offsets.first { abs($0 - scroll.contentOffset.y) > 1 }
        }

        /// Motion in one frame, read after a commit (an uncommitted change
        /// draws the old frame and would look like motion): a running
        /// animation, the transcript drawn faded, or the scroll position
        /// drawn short of where the jump lands.
        func sample() -> String? {
            CATransaction.flush()
            let keys = (scroll.layer.animationKeys() ?? []) + (content.layer.animationKeys() ?? [])
            let opacity = content.layer.presentation()?.opacity ?? content.layer.opacity
            let drawnY = scroll.layer.presentation()?.bounds.origin.y ?? scroll.contentOffset.y
            guard !keys.isEmpty || content.alpha < 1 || opacity < 1 || abs(drawnY - scroll.contentOffset.y) > 0.5 else { return nil }
            return "keys \(keys), alpha \(content.alpha), drawn opacity \(opacity), drawn y \(drawnY), y \(scroll.contentOffset.y)"
        }
        /// The first frame that moved over the next ~120 ms, or nil when
        /// every frame was at rest.
        func motion() -> String? {
            for wait in [0, 0.02, 0.04, 0.04, 0.04] {
                if wait > 0 { RunLoop.main.run(until: Date().addingTimeInterval(wait)) }
                if let moved = sample() { return moved }
            }
            return nil
        }
    }

    /// A transcript many screens tall, read from its top.
    func transcript(reducesMotion: Bool) throws -> Transcript {
        let store = AgentChatStore(source: SmoothChatTests.Silent())
        store.nextFrame = nil
        store.apply(.batch((0..<120).flatMap { SmoothChatTests.turn($0) }))
        let controller = ChatTranscriptController(
            placement: .owned, surface: AgentChatSurface(), store: store,
            empty: AnyView(EmptyView()), dock: AnyView(Color.clear.frame(height: 96)), jump: nil
        )
        controller.reducesMotion = { reducesMotion }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        let scroll = try #require(controller.view.subviews.lazy.compactMap { $0 as? ChatTranscriptCollectionView }.first)
        // The list lays its rows out over later turns of the run loop.
        for _ in 0 ..< 100 where scroll.contentSize.height < 8000 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            controller.view.layoutIfNeeded()
        }
        try #require(scroll.contentSize.height >= 8000, "content measured \(scroll.contentSize.height)")
        // Up at the first turn, no longer following the newest one.
        controller.scrollTranscript(toContentY: 0, animated: false)
        #expect(scroll.contentOffset.y < scroll.bounds.height)
        // A reader rests at the top for frames before tapping the button: lay
        // out and commit the top. A layout still pending when the jump starts
        // follows the newest turn (the jump sets following first) and snaps
        // to the bottom before the jump's own scroll, which hides its motion.
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        controller.view.layoutIfNeeded()
        CATransaction.flush()
        #expect(scroll.contentOffset.y < scroll.bounds.height)
        return Transcript(controller: controller, scroll: scroll, window: window)
    }

    @Test func aLongJumpLandsAtOnceWithTheTranscriptShown() throws {
        let transcript = try transcript(reducesMotion: true)
        defer { transcript.window.isHidden = true }
        let path = transcript.jump()
        #expect(transcript.cut(path) == nil, "no cut short of the bottom: \(path.offsets)")
        #expect(!path.opacities.contains { $0 < 1 }, "the transcript is never hidden: \(path.opacities)")
        let motion = transcript.motion()
        #expect(motion == nil, "no fade and no spring: \(motion ?? "")")
        #expect(transcript.content.alpha == 1)
        #expect(abs(transcript.scroll.contentOffset.y - transcript.bottomY) < 1, "lands on the newest turn")
    }

    /// The oracle sees motion: without Reduce Motion the long jump still
    /// cuts to one screen short and springs the last screen. (The list's
    /// jump never hides the transcript: its rows are cells laid out ahead.)
    @Test func withoutReduceMotionTheLongJumpStillAnimates() throws {
        let transcript = try transcript(reducesMotion: false)
        defer { transcript.window.isHidden = true }
        let path = transcript.jump()
        let cut = try #require(transcript.cut(path), "the long jump cuts first: \(path.offsets)")
        // One screen short of where the jump lands: rows measured as the cut lays them out can
        // move the newest turn's bottom by a few points, which the jump follows (it re-targets).
        let landed = transcript.scroll.contentOffset.y
        #expect(abs(landed - cut - transcript.scroll.bounds.height) < 12, "one screen short: cut \(cut), landed \(landed)")
        #expect(abs(landed - transcript.bottomY) < 12)
    }
}
#endif
