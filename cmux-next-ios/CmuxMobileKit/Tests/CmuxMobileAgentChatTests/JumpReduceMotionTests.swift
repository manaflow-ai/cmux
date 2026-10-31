#if os(iOS)
import SwiftUI
import Testing
import UIKit
@testable import CmuxMobileAgentChat

/// With Reduce Motion on, Jump to latest from far up a long transcript cut,
/// faded and sprang the last screen. It now lands at once. Without Reduce
/// Motion the long jump keeps its cut to one screen short of the target and
/// its spring. (The transcript is a collection view of reused rows, which
/// draws the rows it lands on in the cut's frame: it is no longer hidden for
/// a frame, so there is no fade to check.) An animation writes the final
/// model value at once, so the end point is no proof: each check records
/// every offset the jump wrote on its way, and reads the drawn frames after it.
@MainActor
@Suite(.serialized) struct JumpReduceMotionTests {
    final class Silent: AgentSessionSource {
        let summary = AgentSessionSummary(id: "s", name: "S", harness: "codex", agentName: "Codex", cwd: "~", workspaceTitle: "w", macName: "m")
        func events() -> AsyncStream<AgentSessionEvent> { AsyncStream { _ in } }
        func send(_ intent: AgentClientIntent) {}
    }

    @MainActor
    struct Transcript {
        let controller: ChatTranscriptController
        let scroll: UIScrollView
        let window: UIWindow
        var bottomY: CGFloat { scroll.contentSize.height + scroll.contentInset.bottom - scroll.bounds.height }
        /// What a jump wrote on its way: every scroll offset, in order.
        @MainActor
        final class Path {
            var offsets: [CGFloat] = []
        }

        func jump() -> Path {
            let path = Path()
            let offsets = scroll.observe(\.contentOffset, options: [.new]) { _, change in
                MainActor.assumeIsolated { if let y = change.newValue?.y { path.offsets.append(y) } }
            }
            // The long jump to the newest turn, through the same animated scroll as Jump to latest.
            controller.scrollTranscript(toContentY: scroll.contentSize.height, animated: true)
            offsets.invalidate()
            return path
        }

        /// An offset the jump passed through short of where it lands (the long jump's cut).
        func cut(_ path: Path) -> CGFloat? {
            path.offsets.first { abs($0 - scroll.contentOffset.y) > 1 }
        }

        /// Motion in one frame, read after a commit: a running animation, or the scroll
        /// position drawn short of where the jump lands.
        func sample() -> String? {
            CATransaction.flush()
            let keys = scroll.layer.animationKeys() ?? []
            let drawnY = scroll.layer.presentation()?.bounds.origin.y ?? scroll.contentOffset.y
            guard !keys.isEmpty || abs(drawnY - scroll.contentOffset.y) > 0.5 else { return nil }
            return "keys \(keys), drawn y \(drawnY), y \(scroll.contentOffset.y)"
        }

        /// The first frame that moved over the next ~120 ms, or nil when every frame was at rest.
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
        let store = AgentChatStore(source: Silent())
        store.apply(.batch((0 ..< 60).flatMap { SmoothChatTests.turn($0) }))
        let controller = ChatTranscriptController(placement: .owned, surface: AgentChatSurface(), store: store,
                                                  empty: AnyView(EmptyView()), dock: AnyView(Color.clear.frame(height: 96)), jump: nil)
        controller.reducesMotion = { reducesMotion }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        let scroll = try #require(Self.collection(in: controller.view))
        // Rows are measured on later turns of the run loop.
        for _ in 0 ..< 100 where scroll.contentSize.height < scroll.bounds.height * 6 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            controller.view.layoutIfNeeded()
        }
        try #require(scroll.contentSize.height >= scroll.bounds.height * 6, "content measured \(scroll.contentSize.height)")
        // Up at the first turn, no longer following the newest one.
        controller.scrollTranscript(toContentY: 0, animated: false)
        #expect(scroll.contentOffset.y < scroll.bounds.height)
        // A reader rests at the top for frames before tapping the button: lay out and commit
        // the top, so the jump's motion starts from a committed position.
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        controller.view.layoutIfNeeded()
        CATransaction.flush()
        #expect(scroll.contentOffset.y < scroll.bounds.height)
        return Transcript(controller: controller, scroll: scroll, window: window)
    }

    static func collection(in view: UIView) -> UICollectionView? {
        if let collection = view as? ChatTranscriptCollectionView { return collection }
        for sub in view.subviews { if let found = collection(in: sub) { return found } }
        return nil
    }

    @Test func aLongJumpLandsAtOnceWithTheTranscriptShown() throws {
        let transcript = try transcript(reducesMotion: true)
        defer { transcript.window.isHidden = true }
        let path = transcript.jump()
        #expect(transcript.cut(path) == nil, "no cut short of the bottom: \(path.offsets)")
        let motion = transcript.motion()
        #expect(motion == nil, "no spring: \(motion ?? "")")
        #expect(abs(transcript.scroll.contentOffset.y - transcript.bottomY) < 1, "lands on the newest turn")
    }

    /// The oracle sees motion: without Reduce Motion the long jump still cuts to one screen
    /// short and springs the last screen.
    @Test func withoutReduceMotionTheLongJumpStillAnimates() throws {
        let transcript = try transcript(reducesMotion: false)
        defer { transcript.window.isHidden = true }
        let path = transcript.jump()
        let cut = try #require(transcript.cut(path), "the long jump cuts first: \(path.offsets)")
        // One screen short of where the jump lands (rows measured as the cut lays them out can
        // move the newest turn's bottom by a few points, which the jump follows).
        let landed = transcript.scroll.contentOffset.y
        #expect(abs(landed - cut - transcript.scroll.bounds.height) < 12, "one screen short: cut \(cut), landed \(landed)")
        #expect(abs(landed - transcript.bottomY) < 12)
    }
}
#endif
