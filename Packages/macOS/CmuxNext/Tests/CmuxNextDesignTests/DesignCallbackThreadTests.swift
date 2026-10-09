import AppKit
import Testing
@testable import CmuxNextDesign

@MainActor private final class SystemFlag {
    var on = false
}

/// Design observers registered without a queue (`queue: nil`) run on the
/// posting thread. Posted from a background thread they redraw on main
/// instead of trapping in `MainActor.assumeIsolated`
/// (plans/cmux-next/crash-elimination.md, P1b).
@MainActor @Suite(.serialized) struct DesignCallbackThreadTests {
    /// Posts `name` from a detached thread, then waits one main-queue turn,
    /// which runs after any hop the observer enqueued.
    private func postFromBackground(_ name: Notification.Name, object: (any Sendable)? = nil,
                                    on center: NotificationCenter = .default) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            Thread.detachNewThread {
                center.post(name: name, object: object)
                DispatchQueue.main.async { done.resume() }
            }
        }
    }

    @Test func reduceTransparencyChangedOffMainRedrawsTheSurfaceOnMain() async {
        let flag = SystemFlag()
        let changes = NotificationCenter()
        let state = ReduceTransparency(system: { flag.on }, changes: changes)
        let surface = OverlaySurfaceView(reduceTransparency: state)
        #expect(surface.material != .opaque)
        flag.on = true
        await postFromBackground(NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, on: changes)
        #expect(surface.material == .opaque)
    }

    @Test func aClipFrameChangePostedOffMainUpdatesTheElasticityOnMain() async {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 50))
        scrollView.documentView = document
        let elasticity = ScrollFitElasticity(scrollView: scrollView)
        #expect(scrollView.verticalScrollElasticity == .none)
        document.postsFrameChangedNotifications = false
        document.frame.size.height = 500
        #expect(scrollView.verticalScrollElasticity == .none)
        await postFromBackground(NSView.frameDidChangeNotification, object: scrollView.contentView)
        #expect(scrollView.verticalScrollElasticity == .allowed)
        withExtendedLifetime(elasticity) {}
    }

    @Test func aReduceMotionChangePostedOffMainReachesTheIndicatorConfig() async {
        defer { Motion.reduceMotionOverride = nil }
        let appearance = StatusIndicatorAppearance()
        Motion.reduceMotionOverride = true
        await postFromBackground(Motion.reduceMotionDidChange)
        #expect(!appearance.config.animatesLoops)
    }
}
