import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBrowser
@testable import CmuxNextDesign
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Testing

/// FRAME OWNER REFACTOR S7, Chromium's page tracker in a window's live resize. The CEF fork's `CmuxParentViewTracker`
/// observes `NSViewFrameDidChangeNotification` on a page's `CEFHostView` and on every ancestor, and on each notice works
/// the page out again and moves its page window (a window server call; Chromium lays its views out for a new size). AppKit
/// applies each drag of a live resize with a `setFrame` that lays the window's tree out top-down inside it, so each
/// ancestor posted its notice before the views under it had their new frames: the tracker moved the page window to
/// in-between places several times per applied drag (round s7-profile-on2, build 948b6ff3: Chromium code 32 % of the busy
/// main samples, `-[NSWindow _setFrameCommon:]` called from Chromium 13.9 %). Now the host and its ancestors post their
/// notices when the applied drag's `setFrame` returns: at most one per view, each with the final geometry.
///
/// The tracker here observes as the fork does and records, at each notice, where the host is on screen. The rig is
/// `WindowLiveResizeFrameTickTests`'s, with a `CEFHostView` filling the left pane (it grows as the window does).
@MainActor
@Suite(.serialized, .closesItsWindows)
struct LiveResizePageTrackerNoticesTests {
    /// Observes the host's frame and every ancestor's, as the fork's tracker does (up to the window's content view).
    final class Tracker {
        private(set) var notices: [(view: ObjectIdentifier, hostOnScreen: CGRect)] = []
        private var observers: [any NSObjectProtocol] = []

        init(host: NSView) {
            var view: NSView? = host
            while let current = view {
                // global-notice-allow: the fork's tracker observes these views' frame notices on the default center (the production path)
                observers.append(NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: current,
                                                                        queue: nil) { [weak self, weak host] note in
                    MainActor.assumeIsolated { // main-proof: AppKit posts frame notices on the main thread
                        guard let self, let host, let window = host.window, let object = note.object as? NSView else { return }
                        self.notices.append((ObjectIdentifier(object), window.convertToScreen(host.convert(host.bounds, to: nil))))
                    }
                })
                if current === host.window?.contentView { break }
                view = current.superview
            }
        }

        func reset() { notices.removeAll() }

        func stop() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
        }
    }

    @Test func eachAppliedDragShowsTheTrackerOnlyTheFinalGeometryOncePerView() throws {
        try WindowLiveResizeFrameTickTests.withSwitch(true) {
            let rig = WindowLiveResizeFrameTickTests.Rig()
            defer { rig.close() }
            let window = rig.window
            let pane = try #require(rig.root.contentView(for: "p1"), "the left pane has no content view")
            let host = CEFHostView(frame: pane.bounds)
            host.autoresizingMask = [.width, .height]
            pane.addSubview(host)
            rig.root.layoutSubtreeIfNeeded()
            let tracker = Tracker(host: host)
            defer { tracker.stop() }
            let press = try rig.pressPoint()
            window.sendEvent(rig.event(.leftMouseDown, press))
            Motion.liveResizeOverride = true
            defer { Motion.liveResizeOverride = nil }

            for step in 1...3 {
                tracker.reset()
                let before = window.convertToScreen(host.convert(host.bounds, to: nil))
                window.sendEvent(rig.event(.leftMouseDragged, CGPoint(x: press.x + 24 * CGFloat(step), y: press.y)))
                rig.frameTick()
                window.layoutIfNeeded()
                let final = window.convertToScreen(host.convert(host.bounds, to: nil))
                try #require(final != before, "step \(step): the page host did not change; the test proves nothing")
                let stale = tracker.notices.filter { $0.hostOnScreen != final }.map(\.hostOnScreen), count = tracker.notices.count
                #expect(stale.isEmpty, "step \(step): \(stale.count) of \(count) notices showed the tracker an in-between host: \(stale) (final \(final))")
                let views = Dictionary(grouping: tracker.notices, by: \.view).mapValues(\.count)
                #expect(views.values.allSatisfy { $0 == 1 }, "step \(step): a view posted more than one notice: \(views.values.sorted())")
                #expect(!tracker.notices.isEmpty, "step \(step): the tracker heard nothing of the resize")
            }
            window.sendEvent(rig.event(.leftMouseUp, CGPoint(x: press.x + 72, y: press.y)))
        }
    }
}
