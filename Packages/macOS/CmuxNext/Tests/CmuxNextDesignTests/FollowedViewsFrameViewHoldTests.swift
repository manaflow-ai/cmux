#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
@testable import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// FRAME OWNER REFACTOR S7's diagnostic `motion.frameOwner.liveResize.holdsToRoot` (DEBUG and bench builds). The CEF
/// fork's tracker observes the frame and bounds notices of a page host and of every ancestor up to the window's frame
/// view; ``FollowedViews``' hold stops at the content view, so the frame view's notice, which AppKit posts before it lays
/// the tree out in a live resize's `setFrame`, still reaches the tracker with the host at its old place. Held through the
/// frame view, no notice the tracker observes goes during the hold, and each view posts at most one when it ends.
@MainActor
@Suite(.serialized, .closesItsWindows)
struct FollowedViewsFrameViewHoldTests {
    /// Counts each view's frame and bounds notices, as the fork's tracker observes them.
    final class Recorder {
        private(set) var frames: [ObjectIdentifier: Int] = [:]
        private(set) var bounds: [ObjectIdentifier: Int] = [:]
        private var observers: [any NSObjectProtocol] = []

        init(_ views: [NSView]) {
            for view in views {
                view.postsFrameChangedNotifications = true
                view.postsBoundsChangedNotifications = true
                let id = ObjectIdentifier(view)
                // global-notice-allow: the fork's tracker observes these views' notices on the default center (the production path)
                observers.append(NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: view,
                                                                        queue: nil) { [weak self] _ in
                    MainActor.assumeIsolated { self?.frames[id, default: 0] += 1 } // main-proof: AppKit posts frame notices on the main thread
                })
                // global-notice-allow: the fork's tracker observes these views' notices on the default center (the production path)
                observers.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: view,
                                                                        queue: nil) { [weak self] _ in
                    MainActor.assumeIsolated { self?.bounds[id, default: 0] += 1 } // main-proof: AppKit posts bounds notices on the main thread
                })
            }
        }

        func reset() {
            frames.removeAll()
            bounds.removeAll()
        }

        func stop() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
        }
    }

    @Test func aHoldThroughTheFrameViewHoldsEveryNoticeTheTrackerObservesUntilItEnds() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 300), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView = content
        let followed = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 300))
        followed.autoresizingMask = [.width, .height]
        content.addSubview(followed)
        let frameView = try #require(content.superview, "SETUP: the window has no frame view")
        FollowedViews.of(window).add(followed)
        let recorder = Recorder([followed, content, frameView])
        defer { recorder.stop() }
        let frameViewID = ObjectIdentifier(frameView)

        // The default hold (up to the content view): the frame view's notice goes during it.
        FollowedViews.of(window).beginHold()
        window.setFrame(NSRect(x: 112, y: 108, width: 388, height: 292), display: false)
        frameView.layoutSubtreeIfNeeded()
        let duringDefault = recorder.frames[frameViewID] ?? 0
        FollowedViews.of(window).endHold()
        #expect(duringDefault >= 1, "SETUP: the frame view posted no notice during the default hold; the test proves nothing")
        recorder.reset()

        // Through the frame view: nothing during the hold, each view at most once at its end, and the frame view once.
        let before = followed.frame
        FollowedViews.of(window).beginHold(throughFrameView: true)
        window.setFrame(NSRect(x: 124, y: 116, width: 376, height: 284), display: false)
        frameView.layoutSubtreeIfNeeded()
        #expect(recorder.frames.isEmpty && recorder.bounds.isEmpty, "notices during the hold: frames \(recorder.frames), bounds \(recorder.bounds)")
        FollowedViews.of(window).endHold()
        #expect(recorder.frames[frameViewID] == 1, "the frame view's notice at the hold's end: \(recorder.frames)")
        #expect(recorder.frames.values.allSatisfy { $0 == 1 } && recorder.bounds.values.allSatisfy { $0 == 1 },
                "a view posted more than once at the hold's end: frames \(recorder.frames), bounds \(recorder.bounds)")
        if followed.frame != before {
            #expect(recorder.frames[ObjectIdentifier(followed)] == 1, "the followed view moved and did not post: \(recorder.frames)")
        }
        #expect([followed, content, frameView].allSatisfy { $0.postsFrameChangedNotifications && $0.postsBoundsChangedNotifications },
                "the hold's end did not give every view its notices back")
    }
}
#endif
