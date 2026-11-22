import AppKit
import CmuxNextDesign
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Testing

/// A divider drag moves the pane views on every display frame. Each frame notice a pane view posts makes AppKit
/// mark the window's drag margins dirty when the view has controls in the titlebar band (the tab strip) or is
/// their ancestor (`-[NSView _postFrameChangeNotification]` calls `-[NSWindow _setNeedsToResetDragMargins:]`).
/// The commit of that frame then walks the window's views again for the titlebar drag shapes and sends them to
/// the window server (`_resetDragMarginsIfNeeded`, about a quarter of the drag frame's commit, RESIZE P0 17
/// sample on cmux21). cmux moves its windows only with `performDrag` (`TitlebarDragPolicy`), so that work is
/// waste. The drag's frames post no frame notice from the pane views; the landing posts once per moved view.
@MainActor
@Suite(.closesItsWindows)
struct ResizeDragFrameNoticeTests {
    /// Frame notices per posting view, for the views it watches.
    @MainActor
    final class Notices {
        private(set) var counts: [ObjectIdentifier: Int] = [:]
        private var watched: Set<ObjectIdentifier> = []
        private var token: (any NSObjectProtocol)?

        init(watching views: [NSView]) {
            watched = Set(views.map(ObjectIdentifier.init))
            token = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: nil,
                                                           queue: nil) { [weak self] note in
                guard let poster = note.object as? NSView else { return }
                let id = ObjectIdentifier(poster)
                MainActor.assumeIsolated { self?.note(id) }
            }
        }

        private func note(_ id: ObjectIdentifier) {
            guard watched.contains(id) else { return }
            counts[id, default: 0] += 1
        }

        var total: Int { counts.values.reduce(0, +) }
        func reset() { counts = [:] }
        func stop() {
            if let token { NotificationCenter.default.removeObserver(token) }
            token = nil
        }
    }

    static func subtree(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(subtree) }

    @Test func aDragsFramesPostNoFrameNoticeFromThePaneViewsAndTheLandingPostsOnce() throws {
        let harness = PaneResizeGestureTests.Harness()
        defer { harness.window.closeAfterTest() }
        let hosts = try ["p1", "p2"].map { try #require(harness.root.context.hosts[$0]) }
        let before = hosts.map(\.frame)
        let notices = Notices(watching: hosts.flatMap(Self.subtree))
        defer { notices.stop() }
        let handle = try harness.handle
        let start = try harness.center()
        handle.mouseDown(with: harness.event(.leftMouseDown, start))
        for step in 1...20 {
            handle.mouseDragged(with: harness.event(.leftMouseDragged, CGPoint(x: start.x - CGFloat(step) * 8, y: start.y)))
            harness.root.syncWithModel()
            harness.frame()
            harness.root.layoutSubtreeIfNeeded()
        }
        let during = hosts.map(\.frame)
        // SETUP: the drag moved both panes, so each frame changed pane views' frames.
        try #require(zip(before, during).allSatisfy { $0 != $1 }, "SETUP: the drag moved no pane: \(before) -> \(during)")
        #expect(notices.total == 0, "20 drag frames posted \(notices.total) frame notices from the pane views")
        handle.mouseUp(with: harness.event(.leftMouseUp, CGPoint(x: start.x - 160, y: start.y)))
        harness.root.syncWithModel()
        harness.land()
        for host in hosts {
            #expect(notices.counts[ObjectIdentifier(host)] == 1,
                    "pane \(host.pane) posted \(notices.counts[ObjectIdentifier(host)] ?? 0) notices for the drag, not 1 at its end")
        }
        // After the drag the views post as before.
        notices.reset()
        hosts[1].setFrameSize(CGSize(width: hosts[1].frame.width - 4, height: hosts[1].frame.height))
        #expect(notices.counts[ObjectIdentifier(hosts[1])] == 1, "a pane resized after the drag posted no frame notice")
    }

    /// A page's tracker and a glass lens read their ancestors' notices (`FrameNoticeReaders`): while the drag holds
    /// those, each frame the reader moves in the window tells it once; its own notices, and a scroll view's, post.
    @Test func aDragTellsReadersTheirAncestorsMovesAndKeepsScrollViewsPosting() throws {
        let harness = PaneResizeGestureTests.Harness()
        defer { harness.window.closeAfterTest() }
        let follower = harness.provider.follower
        let reader = NSView(frame: CGRect(x: 10, y: 10, width: 50, height: 50))
        follower.addSubview(reader)
        let scroll = NSScrollView(frame: follower.bounds)
        scroll.autoresizingMask = [.width, .height]
        follower.addSubview(scroll)
        let readers = try #require(reader.enclosingFrameNoticeReaders)
        var moves: [CGRect] = []
        readers.add(reader) { moves.append(reader.convert(reader.bounds, to: nil)) }
        defer { readers.remove(reader) }
        let notices = Notices(watching: [reader, scroll, follower])
        defer { notices.stop() }
        let handle = try harness.handle
        let start = try harness.center()
        handle.mouseDown(with: harness.event(.leftMouseDown, start))
        var shown: Set<CGFloat> = []
        for step in 1...20 {
            handle.mouseDragged(with: harness.event(.leftMouseDragged, CGPoint(x: start.x - CGFloat(step) * 8, y: start.y)))
            harness.root.syncWithModel()
            harness.frame()
            harness.root.layoutSubtreeIfNeeded()
            shown.insert(reader.convert(reader.bounds, to: nil).minX)
        }
        // SETUP: p2's pane moved in the window on the drag's frames, its content resized.
        try #require(shown.count > 10, "SETUP: the reader moved in only \(shown.count) of 20 frames")
        #expect(notices.counts[ObjectIdentifier(follower)] == nil, "the drag posted the held content's notices")
        #expect((notices.counts[ObjectIdentifier(scroll)] ?? 0) > 0, "a scroll view in a dragged pane stopped posting")
        #expect(notices.counts[ObjectIdentifier(reader)] == nil, "the reader's own frame never changed, yet it posted")
        #expect(Set(moves.map(\.minX)) == shown, "the reader heard \(moves.count) moves for \(shown.count) places")
        #expect(moves.last == reader.convert(reader.bounds, to: nil))
    }
}
