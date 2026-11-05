import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBrowser
@testable import CmuxNextDesign
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Testing

/// FRAME OWNER REFACTOR S7, the cost of one live-resize step. A step on the frame tick holds the frame notices of the
/// views Chromium's page tracker follows until its `setFrame` returns (`FollowedViews`), so that the tracker works the
/// page out once, after the layout: at the window's didResize, which AppKit posts when the step's layout is done. Two
/// notices still reached the tracker in the middle of the layout. One is the host view's own geometry post: the page's
/// occlusion work sends it from inside the layout (`CEFTabContentView.layoutContent` and `PageWebView.layout`, through
/// `CEFTab.applyOcclusion`). The other is the frame notice of the window's frame view: the tracker follows the chain up
/// to the root, and the hold stopped at the content view. On each of them the fork moved and resized the page window to
/// an in-between geometry, and Chromium laid the page out there; then it did it again at didResize. Profile ab-s7t
/// (cmux22, 2026-11-05), 1589 samples under the steps' `setFrame`: page-window placements from the host's posts 138
/// samples and from the frame view's notice 42, beside the 120 of the didResize update that the step needs.
///
/// `LiveResizeForkTracker` observes as the fork's `CmuxParentViewTracker` does (chrome_child_window_mac.mm at 3d323193): the host's
/// geometry post, the frame and bounds notices of the host and of every ancestor up to the root (it turns their posts
/// on), and the window's didResize and didMove. Each update reads the host's occlusion rects and clip, as `-applyClip:`
/// does. The rig is `WindowLiveResizeFrameTickTests`'s. A page container in the left pane lays the host out and gives it
/// its occlusion when its size changes, as a CEF tab's content view does for a page before its first real page (native
/// UI covers all of it, so its occlusion changes with each size).
@MainActor
@Suite(.serialized, .closesItsWindows)
struct LiveResizeTrackerAfterLayoutTests {
    /// Each applied drag of a live resize: the tracker hears nothing of the step until the window's didResize (the step's
    /// layout is done there), and it ends the step with the page's final occlusion read.
    @Test func theTrackerHearsALiveResizeStepOnlyAfterItsLayout() throws {
        try WindowLiveResizeFrameTickTests.withSwitch(true) {
            let rig = WindowLiveResizeFrameTickTests.Rig()
            defer { rig.close() }
            let window = rig.window
            let page = try Self.page(in: rig)
            let tracker = LiveResizeForkTracker(host: page.host)
            defer { tracker.stop() }
            let press = try rig.pressPoint()
            window.sendEvent(rig.event(.leftMouseDown, press))
            Motion.liveResizeOverride = true
            defer { Motion.liveResizeOverride = nil }

            for step in 1...3 {
                tracker.reset()
                let before = LiveResizeForkTracker.onScreen(page.host)
                window.sendEvent(rig.event(.leftMouseDragged, CGPoint(x: press.x + 24 * CGFloat(step), y: press.y)))
                rig.frameTick()
                window.layoutIfNeeded()
                let final = LiveResizeForkTracker.onScreen(page.host)
                try #require(final != before, "step \(step): the page host did not change; the test proves nothing")
                try #require(tracker.hostAtDidResize == final,
                             "step \(step): the host was not at its final place at the window's didResize (\(String(describing: tracker.hostAtDidResize)), final \(final)): the rig does not lay out inside setFrame as AppKit's live resize does")
                let early = tracker.updates.filter { !$0.afterDidResize }.map(\.cause)
                #expect(early.isEmpty,
                        "step \(step): the tracker worked the page out \(early.count) times in the middle of the step's layout, before the window's didResize: \(early)")
                #expect(tracker.reads.last == [page.host.bounds],
                        "step \(step): the tracker's last read is not the page's final occlusion: \(tracker.reads.last ?? [])")
            }
            window.sendEvent(rig.event(.leftMouseUp, CGPoint(x: press.x + 72, y: press.y)))
        }
    }

    /// The frame view's frame notice still reaches whoever observes it, once per applied drag.
    @Test func theFrameViewStillPostsItsFrameNoticeOncePerStep() throws {
        try WindowLiveResizeFrameTickTests.withSwitch(true) {
            let rig = WindowLiveResizeFrameTickTests.Rig()
            defer { rig.close() }
            let window = rig.window
            let page = try Self.page(in: rig)
            let tracker = LiveResizeForkTracker(host: page.host)
            defer { tracker.stop() }
            let frameView = try #require(window.contentView?.superview, "the window has no frame view")
            let press = try rig.pressPoint()
            window.sendEvent(rig.event(.leftMouseDown, press))
            Motion.liveResizeOverride = true
            defer { Motion.liveResizeOverride = nil }

            for step in 1...2 {
                tracker.reset()
                window.sendEvent(rig.event(.leftMouseDragged, CGPoint(x: press.x + 30 * CGFloat(step), y: press.y)))
                rig.frameTick()
                let notices = tracker.updates.filter { $0.cause == LiveResizeForkTracker.frameCause(of: frameView) }.count
                #expect(notices == 1, "step \(step): the frame view posted \(notices) frame notices")
            }
            window.sendEvent(rig.event(.leftMouseUp, CGPoint(x: press.x + 60, y: press.y)))
        }
    }

    /// Two pages in one window (review of ec8aedb298a): each page's tracker hears the step only after its layout, and
    /// ends it with its page's final occlusion read.
    @Test func twoPagesInOneWindowEachHearTheStepOnlyAfterItsLayout() throws {
        try WindowLiveResizeFrameTickTests.withSwitch(true) {
            let rig = WindowLiveResizeFrameTickTests.Rig()
            defer { rig.close() }
            let window = rig.window
            let pages = try Self.stackedPages(in: rig)
            let trackers = pages.map { LiveResizeForkTracker(host: $0.host) }
            defer { trackers.forEach { $0.stop() } }
            let press = try rig.pressPoint()
            window.sendEvent(rig.event(.leftMouseDown, press))
            Motion.liveResizeOverride = true
            defer { Motion.liveResizeOverride = nil }

            for step in 1...2 {
                trackers.forEach { $0.reset() }
                let before = pages.map { LiveResizeForkTracker.onScreen($0.host) }
                window.sendEvent(rig.event(.leftMouseDragged, CGPoint(x: press.x + 24 * CGFloat(step), y: press.y)))
                rig.frameTick()
                window.layoutIfNeeded()
                for (index, (page, tracker)) in zip(pages, trackers).enumerated() {
                    try #require(LiveResizeForkTracker.onScreen(page.host) != before[index], "step \(step), page \(index): the host did not change")
                    let early = tracker.updates.filter { !$0.afterDidResize }.map(\.cause)
                    #expect(early.isEmpty, "step \(step), page \(index): \(early.count) updates before didResize: \(early)")
                    #expect(tracker.reads.last == [page.host.bounds], "step \(step), page \(index): last read \(tracker.reads.last ?? [])")
                }
            }
            window.sendEvent(rig.event(.leftMouseUp, CGPoint(x: press.x + 48, y: press.y)))
        }
    }

    /// A hidden page (review of ec8aedb298a): the fork's update reads nothing of a page that does not show, so a post the
    /// hold kept for it goes at the end of the hold, once, after the frame notices.
    @Test func aHiddenPagesHeldPostReachesTheTrackerOnceAtTheEndOfTheHold() throws {
        let rig = WindowLiveResizeFrameTickTests.Rig()
        defer { rig.close() }
        let page = try Self.page(in: rig)
        page.host.isHidden = true
        let tracker = LiveResizeForkTracker(host: page.host)
        defer { tracker.stop() }
        let occlusion = page.host.occlusionRects

        tracker.reset()
        FollowedViews.of(rig.window).holdingFrameNotices {
            // The container lays the host out at its new size and gives it its occlusion (a post).
            page.setFrameSize(NSSize(width: page.frame.width - 20, height: page.frame.height))
        }
        try #require(page.host.occlusionRects != occlusion, "the hidden page's occlusion did not change; the test proves nothing")
        let causes = tracker.updates.map(\.cause)
        let posts = causes.filter { $0 == LiveResizeForkTracker.postCause }.count
        #expect(posts == 1, "the tracker heard \(causes)")
        #expect(causes.last == LiveResizeForkTracker.postCause, "the held post did not come after the frame notices: \(causes)")
        #expect(tracker.reads.isEmpty, "the tracker read a hidden page: \(tracker.reads)")
    }

    /// A change of the page's occlusion in a step's hold that no later read of the tracker covers (nothing moved) still
    /// reaches the tracker once, at the end of the hold.
    @Test func anOcclusionChangeInAHoldThatMovesNothingReachesTheTrackerOnce() throws {
        let rig = WindowLiveResizeFrameTickTests.Rig()
        defer { rig.close() }
        let page = try Self.page(in: rig)
        let tracker = LiveResizeForkTracker(host: page.host)
        defer { tracker.stop() }
        let bar = CGRect(x: 0, y: 0, width: 120, height: 24)

        tracker.reset()
        FollowedViews.of(rig.window).holdingFrameNotices {
            page.host.occlusionRects = [bar]
        }
        #expect(tracker.updates.count == 1, "the tracker updated \(tracker.updates.count) times for one occlusion change")
        #expect(tracker.reads.last?.contains(bar) == true, "the tracker did not read the new occlusion: \(tracker.reads.last ?? [])")
    }

    /// Outside a live-resize step the host's geometry post reaches the tracker at once.
    @Test func outsideAStepAnOcclusionChangeReachesTheTrackerAtOnce() throws {
        let rig = WindowLiveResizeFrameTickTests.Rig()
        defer { rig.close() }
        let page = try Self.page(in: rig)
        let tracker = LiveResizeForkTracker(host: page.host)
        defer { tracker.stop() }
        let bar = CGRect(x: 0, y: 0, width: 120, height: 24)

        tracker.reset()
        page.host.occlusionRects = [bar]
        #expect(tracker.updates.map(\.cause) == [LiveResizeForkTracker.postCause], "the tracker heard \(tracker.updates.map(\.cause))")
        #expect(tracker.reads.last?.contains(bar) == true, "the tracker did not read the new occlusion: \(tracker.reads.last ?? [])")
    }

    /// A page container filling the rig's left pane (it grows with the window), laid out.
    static func page(in rig: WindowLiveResizeFrameTickTests.Rig) throws -> LiveResizeTestPageContainer {
        let pane = try #require(rig.root.contentView(for: "p1"), "the left pane has no content view")
        let page = LiveResizeTestPageContainer(frame: pane.bounds)
        page.autoresizingMask = [.width, .height]
        pane.addSubview(page)
        rig.root.layoutSubtreeIfNeeded()
        return page
    }

    /// Two page containers in the rig's left pane, one over the other; both grow with the window's width.
    static func stackedPages(in rig: WindowLiveResizeFrameTickTests.Rig) throws -> [LiveResizeTestPageContainer] {
        let pane = try #require(rig.root.contentView(for: "p1"), "the left pane has no content view")
        let half = (pane.bounds.height / 2).rounded(.down)
        let pages = [
            LiveResizeTestPageContainer(frame: NSRect(x: 0, y: 0, width: pane.bounds.width, height: half)),
            LiveResizeTestPageContainer(frame: NSRect(x: 0, y: half, width: pane.bounds.width, height: pane.bounds.height - half)),
        ]
        pages[0].autoresizingMask = [.width, .maxYMargin]
        pages[1].autoresizingMask = [.width, .minYMargin]
        pages.forEach(pane.addSubview)
        rig.root.layoutSubtreeIfNeeded()
        return pages
    }
}

/// A CEF tab's content view as the page tracker meets it: lays the host out over itself and gives it its occlusion when
/// its size changes (`CEFTabContentView.layoutContent` -> `CEFTab.applyOcclusion`; native UI covers all of a page
/// before its first real page).
@MainActor final class LiveResizeTestPageContainer: NSView {
    let host: CEFHostView

    override init(frame: NSRect) {
        host = CEFHostView(frame: NSRect(origin: .zero, size: frame.size))
        super.init(frame: frame)
        addSubview(host)
        layoutContent()
    }

    required init?(coder: NSCoder) { nil }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        layoutContent()
    }

    private func layoutContent() {
        host.frame = bounds
        host.occlusionRects = [host.bounds]
    }
}

/// The fork's page tracker for one host view (see the suite's comment).
@MainActor final class LiveResizeForkTracker: NSObject {
    static let postCause = "geometry post"
    static let didResizeCause = "didResize"
    static let didMoveCause = "didMove"

    static func frameCause(of view: NSView) -> String { "frame of \(type(of: view))" }

    /// What woke each update, in order, and whether the window's didResize had come before it in this step.
    private(set) var updates: [(cause: String, afterDidResize: Bool)] = []
    /// The occlusion rects each update read (`-cmuxOcclusionRects`).
    private(set) var reads: [[CGRect]] = []
    /// The host's rect on screen at the window's didResize of this step.
    private(set) var hostAtDidResize: CGRect?
    private var sawDidResize = false
    private var updating = false
    private let host: CEFHostView

    init(host: CEFHostView) {
        self.host = host
        super.init()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(geometryPosted), name: CEFHostView.geometryDidChange, object: host)
        var view: NSView? = host
        while let current = view {
            current.postsFrameChangedNotifications = true
            current.postsBoundsChangedNotifications = true
            center.addObserver(self, selector: #selector(frameChanged(_:)), name: NSView.frameDidChangeNotification, object: current)
            center.addObserver(self, selector: #selector(boundsChanged(_:)), name: NSView.boundsDidChangeNotification, object: current)
            view = current.superview
        }
        center.addObserver(self, selector: #selector(windowResized), name: NSWindow.didResizeNotification, object: host.window)
        center.addObserver(self, selector: #selector(windowMoved), name: NSWindow.didMoveNotification, object: host.window)
    }

    /// Forgets what the tracker heard: the next step starts before its didResize.
    func reset() {
        updates = []
        reads = []
        hostAtDidResize = nil
        sawDidResize = false
    }

    func stop() {
        NotificationCenter.default.removeObserver(self)
    }

    static func onScreen(_ view: NSView) -> CGRect {
        guard let window = view.window else { return .null }
        return window.convertToScreen(view.convert(view.bounds, to: nil))
    }

    @objc private func geometryPosted() { update(Self.postCause) }

    @objc private func frameChanged(_ note: Notification) {
        update((note.object as? NSView).map(Self.frameCause(of:)) ?? "frame")
    }

    @objc private func boundsChanged(_ note: Notification) {
        update("bounds of \((note.object as? NSView).map { "\(type(of: $0))" } ?? "?")")
    }

    @objc private func windowResized() {
        if !sawDidResize { hostAtDidResize = Self.onScreen(host) }
        sawDidResize = true
        update(Self.didResizeCause)
    }

    @objc private func windowMoved() { update(Self.didMoveCause) }

    /// The fork's `-update`: one at a time; a page that does not show reads nothing (the fork hides its window and
    /// returns); a shown page is placed over the host, then reads the clip inputs.
    private func update(_ cause: String) {
        guard !updating else { return }
        updating = true
        defer { updating = false }
        updates.append((cause, sawDidResize))
        guard let window = host.window, window.isVisible, !host.isHiddenOrHasHiddenAncestor, !host.bounds.isEmpty else { return }
        reads.append((host.cmuxOcclusionRects() as? [NSValue] ?? []).map(\.rectValue))
        _ = host.cmuxClipPath()
    }
}
