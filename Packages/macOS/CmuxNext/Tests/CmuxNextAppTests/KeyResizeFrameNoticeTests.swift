import AppKit
import CmuxNextBridge
import CmuxNextDesign
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Testing

/// A keyboard resize moves and resizes the pane views on every frame of its spring, as a divider drag does. The
/// Chromium fork's page tracker reads the frame notice of the page's host view and of each ancestor of it, and runs
/// its whole update for each one (a main-thread sample of a key resize, hold ps2: 8 updates a frame for a file viewer
/// or the Settings page, one for each of the page's host and its 7 ancestors). Each notice of a pane view also makes
/// AppKit walk the window's titlebar drag shapes in that frame's commit (`ResizeDragFrameNoticeTests`).
///
/// The key resize holds the pane views' frame notices from the press to the frame its spring lands in, with the hold
/// a divider drag and a zoom have (`FrameNoticeHold`, #38849): a frame posts the notice of the page's host alone (a
/// reader, never held), and each view that moved posts once at the landing.
@MainActor
@Suite(.closesItsWindows)
struct KeyResizeFrameNoticeTests {
    typealias Notices = ResizeDragFrameNoticeTests.Notices

    /// Pane content that follows its pane in every frame of a key hold (`PaneMotionHolding` with an area), with the
    /// stand-ins of what the app puts between a pane's content area and a Chromium page's host view: the page tab's
    /// view, its web view, the Chromium tab's view and the host view. Each fills its parent, as in the app.
    final class Page: NSView, PaneMotionHolding {
        let area = PaneContentAreaView()
        let page = NSView(), web = NSView(), tab = NSView(), host = NSView()
        var paneMotionHoldArea: PaneContentAreaView? { area }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            var parent: NSView = self
            for view in [area, page, web, tab, host] {
                view.frame = parent.bounds
                view.autoresizingMask = [.width, .height]
                parent.addSubview(view)
                parent = view
            }
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    }

    final class Pages: LayoutPaneContentProvider {
        var views: [PaneID: Page] = [:]
        func makeContentView(for pane: PaneID) -> NSView {
            let view = Page()
            views[pane] = view
            return view
        }
    }

    /// p1 | p2 in one column, p2 focused: a press to the left on p2 moves the divider, so p2's left edge moves and both
    /// panes change width in every frame of the spring.
    final class Rig {
        let provider = Pages()
        let model: LayoutModel
        let root: LayoutRootView
        let window: KeyResizeFrameNoticeLiveResizeWindow
        var afterCommit: [@MainActor () -> Void] = []

        /// `strip`: two more columns (p3, p4) and each column half the window wide, so the strip is 1.5 windows and has a
        /// camera; `focused` p4 starts it scrolled to its end.
        init(reduceMotion: Bool = false, strip: Bool = false, focused: PaneID = "p2") {
            _ = NSApplication.shared
            var columns = [LayoutColumn(id: "c0", width: strip ? 0.5 : 1, root: .split("x", axis: .horizontal, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2")))]
            if strip { columns += [LayoutColumn(id: "c1", width: 0.5, root: .leaf("p3")), LayoutColumn(id: "c2", width: 0.5, root: .leaf("p4"))] }
            model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .columns(columns))], activeScreenID: "s", focusedPane: focused)
            root = LayoutRootView(model: model, contentProvider: provider)
            root.context.reduceMotionOverride = reduceMotion
            window = KeyResizeFrameNoticeLiveResizeWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = root
            root.layoutSubtreeIfNeeded()
            root.driver.isManual = true
            // Weak: a test that ends in the spring (a failed `#require`) closes its window with motion in flight, and the
            // root's settle asks for after-commit work once this rig is gone (as FrameOwnerS1HoldPathsTests' rig).
            root.context.afterCommit = { [weak self] in self?.afterCommit.append($0) }
        }

        var screen: ScreenContentView { get throws { try #require(root.screenViews["s"]) } }

        /// The page's host view of `pane` and its ancestors up to the pane's host, outermost first: the views whose
        /// frame notices the fork's tracker reads.
        func chain(_ pane: PaneID) throws -> [NSView] {
            let paneHost = try #require(root.context.hosts[pane])
            let page = try #require(provider.views[pane])
            var views: [NSView] = []
            var view: NSView? = page.host
            while let current = view, current !== paneHost.superview {
                views.append(current)
                view = current.superview
            }
            try #require(views.last === paneHost, "fixture: pane \(pane)'s page is not under its pane host")
            return views.reversed()
        }

        /// One display frame and its layout pass. Returns whether anything still moves.
        func frame() -> Bool {
            let moving = root.advanceFrame(1.0 / 120)
            root.layoutSubtreeIfNeeded()
            return moving
        }

        /// The work the landing left for after its commit, then the layout it asks for.
        func runAfterCommit() {
            while !afterCommit.isEmpty {
                let work = afterCommit
                afterCommit = []
                for block in work { block() }
            }
            root.layoutSubtreeIfNeeded()
        }
    }

    /// `view`'s rect in its window, rounded to a tenth of a point.
    static func rect(_ view: NSView) -> CGRect {
        let rect = view.convert(view.bounds, to: nil)
        func tenth(_ value: CGFloat) -> CGFloat { (value * 10).rounded() / 10 }
        return CGRect(x: tenth(rect.minX), y: tenth(rect.minY), width: tenth(rect.width), height: tenth(rect.height))
    }

    /// What one spring of a key resize posted, frame by frame, from `watched`.
    struct Spring {
        /// Frame notices of each frame of the spring (the landing's frame is not in it), all watched views together.
        var perFrame: [Int] = []
        /// The widths the pane's host had on the spring's frames.
        var widths: Set<CGFloat> = []
        /// Frame notices of the landing's frame, per view.
        var landing: [ObjectIdentifier: Int] = [:]
    }

    /// Steps the spring a press started to its landing, counting the frame notices of each frame.
    static func run(_ rig: Rig, pane: PaneID, notices: Notices, each: () -> Void = {}) throws -> Spring {
        let paneHost = try #require(rig.root.context.hosts[pane])
        var spring = Spring()
        var frames = 0
        while frames < 240 {
            notices.reset()
            let moving = rig.frame()
            guard moving else { break }
            spring.perFrame.append(notices.total)
            spring.widths.insert(paneHost.frame.width)
            each()
            frames += 1
        }
        spring.landing = notices.counts
        // SETUP: the press ran on a spring that resized the pane over many frames.
        try #require(frames > 5 && frames < 240 && spring.widths.count > 5,
                     "SETUP: the press ran \(frames) frames over \(spring.widths.count) widths")
        return spring
    }

    /// THE COUNT: one frame of a key resize posts ONE frame notice from a page's host view and its 7 ancestors, the
    /// host view's own (it is a reader, as the app's `CEFHostView` is). Without the hold each of the 8 posts in each
    /// frame, and the fork runs its update 8 times. At the landing each held view posts once, every view posts again,
    /// and every view rests where a press with no spring (Reduce Motion, no hold) puts it.
    @Test func aKeyResizesFramePostsOnlyThePagesOwnFrameNoticeAndTheLandingPostsOncePerView() throws {
        let rig = Rig()
        defer { rig.window.closeAfterTest() }
        let chain = try rig.chain("p2")
        let page = try #require(rig.provider.views["p2"])
        // SETUP: the pane's host, its clip, the content, its area, then the 4 views down to the page's host view.
        try #require(chain.count == 8 && chain.last === page.host,
                     "SETUP: the page's host view has \(chain.count - 1) ancestors up to its pane host, not 7: \(chain.map { type(of: $0) })")
        let readers = try #require(page.host.enclosingFrameNoticeReaders)
        var ancestorMoves = 0
        readers.add(page.host) { ancestorMoves += 1 }
        defer { readers.remove(page.host) }
        let held = chain.dropLast()
        let notices = Notices(watching: chain)
        defer { notices.stop() }

        #expect(PaneResize.press("p2", .left, model: rig.model, view: rig.root))
        #expect(notices.total == 0, "the key's turn posted \(notices.total) frame notices from the page's views")
        var ownChanges = 0, last = page.host.frame
        let spring = try Self.run(rig, pane: "p2", notices: notices) {
            if page.host.frame != last { ownChanges += 1 }
            last = page.host.frame
        }
        let worst = spring.perFrame.max() ?? 0
        #expect(worst == 1, "a frame of the key resize posted \(worst) frame notices from the page's host view and its 7 ancestors (want 1, the host view's own); per frame: \(spring.perFrame)")
        // SETUP: the page's host view changed its own frame on the spring's frames.
        try #require(ownChanges > 5, "SETUP: the page's host view changed its frame in only \(ownChanges) frames")
        #expect(spring.perFrame.reduce(0, +) == ownChanges, "the spring posted \(spring.perFrame.reduce(0, +)) frame notices for \(ownChanges) frame changes of the page's host view: \(spring.perFrame)")
        // The page's own frame changed in each frame, so its own notice told the fork: no stand-in call for an ancestor.
        #expect(ancestorMoves == 0, "the reader heard \(ancestorMoves) ancestor moves in frames that changed its own frame")

        // The landing: each held view posts its one notice, and every view of both panes posts again.
        for view in held {
            #expect(spring.landing[ObjectIdentifier(view)] == 1,
                    "\(type(of: view)) posted \(spring.landing[ObjectIdentifier(view)] ?? 0) frame notices at the landing, not 1")
        }
        let hosts = try ["p1", "p2"].map { try #require(rig.root.context.hosts[$0]) }
        let muted = hosts.flatMap(ResizeDragFrameNoticeTests.subtree).filter { !$0.postsFrameChangedNotifications }
        #expect(muted.isEmpty, "\(muted.count) pane views post no frame notice after the key resize landed: \(muted.map { type(of: $0) })")

        // The rest: the same rects as a press that never springs and never holds.
        rig.runAfterCommit()
        let still = Rig(reduceMotion: true)
        defer { still.window.closeAfterTest() }
        #expect(PaneResize.press("p2", .left, model: still.model, view: still.root))
        for _ in 0..<3 { _ = still.frame() }
        still.runAfterCommit()
        let stillChain = try still.chain("p2")
        #expect(chain.map(Self.rect) == stillChain.map(Self.rect),
                "at rest the page's views are at \(chain.map(Self.rect)); a press with no spring puts them at \(stillChain.map(Self.rect))")

        // After the key resize the views post as before.
        notices.reset()
        hosts[1].setFrameSize(CGSize(width: hosts[1].frame.width - 4, height: hosts[1].frame.height))
        #expect(notices.counts[ObjectIdentifier(hosts[1])] == 1, "a pane resized after the key resize posted no frame notice")
    }

    /// A key repeat: a second press while the first one's spring runs keeps the hold. A release between two presses
    /// would post each moved view's notice once per press.
    @Test func aSecondPressOnTheSpringPostsNoFrameNoticeFromThePaneViews() throws {
        let rig = Rig()
        defer { rig.window.closeAfterTest() }
        let chain = try rig.chain("p2")
        let held = Array(chain.dropLast())
        let page = try #require(rig.provider.views["p2"])
        let readers = try #require(page.host.enclosingFrameNoticeReaders)
        readers.add(page.host) {}
        defer { readers.remove(page.host) }
        let notices = Notices(watching: held)
        defer { notices.stop() }
        #expect(PaneResize.press("p2", .left, model: rig.model, view: rig.root))
        for _ in 0..<3 { _ = rig.frame() }
        // SETUP: the first press is still on its spring.
        try #require(try rig.screen.hasMotion, "SETUP: the first press landed in 3 frames")
        #expect(notices.total == 0, "3 frames of the first press posted \(notices.total) frame notices from the pane views")
        #expect(PaneResize.press("p2", .left, model: rig.model, view: rig.root))
        #expect(notices.total == 0, "the second press's turn posted \(notices.total) frame notices from the pane views")
        let spring = try Self.run(rig, pane: "p2", notices: notices)
        #expect(spring.perFrame.allSatisfy { $0 == 0 }, "the frames after the second press posted frame notices from the pane views: \(spring.perFrame)")
        for view in held {
            #expect(spring.landing[ObjectIdentifier(view)] == 1,
                    "\(type(of: view)) posted \(spring.landing[ObjectIdentifier(view)] ?? 0) frame notices at the landing of 2 presses, not 1")
        }
    }

    /// A reader whose own frame does not change (a page in a pane that moves and keeps its size) hears each frame its
    /// held ancestors moved it in the window, once, as in a divider drag.
    @Test func aKeyResizeTellsAReaderItsAncestorsMoves() throws {
        let rig = Rig()
        defer { rig.window.closeAfterTest() }
        let page = try #require(rig.provider.views["p2"])
        // At p2's leading edge, with a fixed frame: the divider moves it in the window and never resizes it.
        let reader = NSView(frame: CGRect(x: 10, y: 10, width: 50, height: 50))
        page.area.addSubview(reader)
        let readers = try #require(reader.enclosingFrameNoticeReaders)
        var moves: [CGFloat] = []
        readers.add(reader) { moves.append(reader.convert(reader.bounds, to: nil).minX) }
        defer { readers.remove(reader) }
        let notices = Notices(watching: [reader])
        defer { notices.stop() }
        var shown: Set<CGFloat> = []
        let start = reader.convert(reader.bounds, to: nil).minX
        #expect(PaneResize.press("p2", .left, model: rig.model, view: rig.root))
        let none = Notices(watching: [])
        defer { none.stop() }
        _ = try Self.run(rig, pane: "p2", notices: none) {
            let now = reader.convert(reader.bounds, to: nil).minX
            if now != start { shown.insert(now) }
        }
        // SETUP: the reader moved in the window on the spring's frames.
        try #require(shown.count > 5, "SETUP: the reader moved to only \(shown.count) places")
        #expect(notices.total == 0, "the reader's own frame never changed, yet it posted \(notices.total) frame notices")
        #expect(shown.isSubset(of: Set(moves)), "the reader heard \(Set(moves).count) of its places for \(shown.count) it was shown at")
    }

    /// The named limit (F1 of #38849's review, not changed here): the hold stops at the first reader. With a glass
    /// lens the app's page web view is a reader too (`GlassBackdropFeed`), so it, the view under it and the page's
    /// host view keep posting: 3 notices a frame, not 1. The 5 views above the web view post nothing.
    @Test func aReaderAboveThePagesHostViewKeepsTheViewsUnderItPosting() throws {
        let rig = Rig()
        defer { rig.window.closeAfterTest() }
        let chain = try rig.chain("p2")
        let page = try #require(rig.provider.views["p2"])
        let readers = try #require(page.host.enclosingFrameNoticeReaders)
        readers.add(page.web) {}
        readers.add(page.host) {}
        defer {
            readers.remove(page.web)
            readers.remove(page.host)
        }
        let glass = try #require(chain.firstIndex { $0 === page.web })
        let above = Array(chain[..<glass])
        let all = Notices(watching: chain), held = Notices(watching: above)
        defer {
            all.stop()
            held.stop()
        }
        #expect(PaneResize.press("p2", .left, model: rig.model, view: rig.root))
        var heldPerFrame: [Int] = []
        var before = 0
        let spring = try Self.run(rig, pane: "p2", notices: all) {
            heldPerFrame.append(held.total - before)
            before = held.total
        }
        #expect(heldPerFrame.allSatisfy { $0 == 0 }, "the \(above.count) views above the glass reader posted frame notices on the spring's frames: \(heldPerFrame)")
        #expect(spring.perFrame.max() == 3 && spring.perFrame.allSatisfy { $0 == 3 || $0 == 0 },
                "a frame posted other than the 3 notices of the glass reader, the view under it and the page's host view: \(spring.perFrame)")
    }

    /// The hold ends with the key hold on every path: a spring landed at once (a window out of sight, Reduce Motion
    /// turned on), a structural change that takes the screen over, and a press that does not spring. A view left
    /// without its notices would never tell its readers a later move.
    @Test func theHoldEndsWithTheKeyHoldOnEveryPath() throws {
        func muted(_ rig: Rig) -> [NSView] {
            rig.root.context.hosts.values.flatMap(ResizeDragFrameNoticeTests.subtree).filter { !$0.postsFrameChangedNotifications }
        }
        // Landed at once.
        let landed = Rig()
        defer { landed.window.closeAfterTest() }
        #expect(PaneResize.press("p2", .left, model: landed.model, view: landed.root))
        _ = landed.frame()
        try #require(!muted(landed).isEmpty, "a key resize on its spring holds no pane view's frame notices, so no path can end the hold")
        landed.root.landMotion()
        #expect(muted(landed).isEmpty, "landMotion left \(muted(landed).count) pane views without frame notices")

        // A split of p2 while the key spring runs.
        let split = Rig()
        defer { split.window.closeAfterTest() }
        #expect(PaneResize.press("p2", .left, model: split.model, view: split.root))
        _ = split.frame()
        let columns = [LayoutColumn(id: "c0", width: 1, root: .split("x", axis: .horizontal, ratio: 0.45, a: .leaf("p1"),
                                                                     b: .split("y", axis: .vertical, ratio: 0.5, a: .leaf("p2"), b: .leaf("p3"))))]
        split.model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: .columns(columns))])
        split.root.syncWithModel()
        #expect(muted(split).isEmpty, "a split during the key spring left \(muted(split).count) pane views without frame notices in its turn")
        var frames = 0
        while frames < 240, split.frame() { frames += 1 }
        #expect(muted(split).isEmpty, "\(muted(split).count) pane views post no frame notice after the split landed")

        // A press that does not spring.
        let still = Rig(reduceMotion: true)
        defer { still.window.closeAfterTest() }
        #expect(PaneResize.press("p2", .left, model: still.model, view: still.root))
        #expect(muted(still).isEmpty, "a press with Reduce Motion holds \(muted(still).count) pane views' frame notices")
        _ = still.frame()
        #expect(muted(still).isEmpty, "a press with Reduce Motion left \(muted(still).count) pane views without frame notices")
    }

    /// A live window resize snaps the key spring where it was going (`ScreenContentView.setFrameSize`): nothing moves
    /// after it and no landing frame comes, so the key hold and its frame notice hold end in that turn. Left on, the
    /// pane views would post no frame notice until a later key resize landed.
    @Test func aLiveWindowResizeInTheSpringEndsTheHold() throws {
        let rig = Rig()
        defer { rig.window.closeAfterTest() }
        let screen = try rig.screen
        func muted() -> [NSView] {
            rig.root.context.hosts.values.flatMap(ResizeDragFrameNoticeTests.subtree).filter { !$0.postsFrameChangedNotifications }
        }
        #expect(PaneResize.press("p2", .left, model: rig.model, view: rig.root))
        _ = rig.frame()
        // SETUP: the press is on its spring.
        try #require(screen.hasMotion && screen.holdsContentForKeyResize, "SETUP: the press is not on its spring after one frame")
        try #require(!muted().isEmpty, "a key resize on its spring holds no pane view's frame notices, so a live resize can end no hold")

        let before = screen.frame.size
        rig.window.isLive = true
        rig.window.setContentSize(NSSize(width: 1100, height: 760))
        rig.root.layoutSubtreeIfNeeded()
        rig.window.isLive = false
        // SETUP: the live resize gave the screen a new size and snapped the spring.
        try #require(screen.frame.size != before, "SETUP: the window resize did not resize the screen (\(screen.frame.size))")
        try #require(!screen.hasMotion, "SETUP: the live resize did not snap the key spring")

        #expect(!screen.holdsContentForKeyResize, "the key hold outlived the spring a live window resize snapped")
        #expect(muted().isEmpty, "a live window resize in the key spring left \(muted().count) pane views without frame notices")
    }

    /// The same live window resize while the strip's camera is still on its way (the focus went to another column just
    /// before the press): the resize snaps the panes, and the camera's frames go on. The key spring is over, so the key
    /// hold and its frame notice hold end in the resize's turn, not at the camera's landing: the pane views post as in
    /// any camera scroll, and a spring that starts before the camera lands is not taken for a key resize's.
    @Test func aLiveWindowResizeEndsTheHoldWhileTheCameraStillMoves() throws {
        let rig = Rig(strip: true, focused: "p4")
        defer { rig.window.closeAfterTest() }
        let screen = try rig.screen
        func muted() -> [NSView] {
            rig.root.context.hosts.values.flatMap(ResizeDragFrameNoticeTests.subtree).filter { !$0.postsFrameChangedNotifications }
        }
        func panesMove() -> Bool { screen.paneFrames.values.contains { $0.rect != $0.targetRect } }
        func cameraMoves() -> Bool { screen.scroll.value != screen.scroll.target }
        var frames = 0
        while frames < 600, rig.frame() { frames += 1 }
        // SETUP: at rest, the strip scrolled to its end for p4.
        try #require(!screen.hasMotion && screen.scroll.value > 100, "SETUP: the strip of 3 half-width columns rests at offset \(screen.scroll.value) for p4")
        // The focus goes to p2 in the first column: the camera springs back to the strip's start.
        rig.model.focus("p2", notify: false)
        rig.root.syncWithModel()
        _ = rig.frame()
        try #require(cameraMoves(), "SETUP: the focus move to p2 did not put the camera on a spring (offset \(screen.scroll.value), target \(screen.scroll.target))")
        #expect(PaneResize.press("p2", .left, model: rig.model, view: rig.root))
        _ = rig.frame()
        // SETUP: the press is on its spring, and the camera is still on its own.
        try #require(panesMove() && cameraMoves() && screen.holdsContentForKeyResize, "SETUP: after one frame of the press the panes \(panesMove() ? "move" : "rest") and the camera \(cameraMoves() ? "moves" : "rests")")
        try #require(!muted().isEmpty, "a key resize on its spring holds no pane view's frame notices, so a live resize can end no hold")

        let before = screen.frame.size
        rig.window.isLive = true
        rig.window.setContentSize(NSSize(width: 1100, height: 760))
        rig.root.layoutSubtreeIfNeeded()
        rig.window.isLive = false
        // SETUP: the live resize gave the screen a new size and snapped the panes, and the camera still moves.
        try #require(screen.frame.size != before, "SETUP: the window resize did not resize the screen (\(screen.frame.size))")
        try #require(!panesMove(), "SETUP: the live resize did not snap the panes of the key spring")
        try #require(cameraMoves() && screen.hasMotion, "SETUP: the camera does not move after the live resize (offset \(screen.scroll.value), target \(screen.scroll.target))")

        #expect(!screen.holdsContentForKeyResize, "the key hold outlived the pane spring a live window resize snapped, for as long as the camera moves")
        #expect(muted().count == 0, "a live window resize in the key spring left \(muted().count) pane views without frame notices while the camera moves")
        // THE COUNT: a pane view resized now posts its one frame notice.
        let host = try #require(rig.root.context.hosts["p2"])
        let notices = Notices(watching: [host])
        defer { notices.stop() }
        host.setFrameSize(CGSize(width: host.frame.width - 4, height: host.frame.height))
        #expect(notices.counts[ObjectIdentifier(host)] == 1, "a pane resized while the camera moves posted \(notices.counts[ObjectIdentifier(host)] ?? 0) frame notices, not 1")
        // The camera lands: nothing is held at rest.
        frames = 0
        while frames < 600, rig.frame() { frames += 1 }
        #expect(!screen.hasMotion && !screen.holdsContentForKeyResize && muted().isEmpty, "at the camera's landing \(muted().count) pane views post no frame notice")
    }

    /// The carried spring: a window resize that is not live (the sidebar's slide, a zoom of the window by a key)
    /// carries the key spring into the new size (`reconcileAndScroll(keepsMotion:)`), so the key hold and its frame
    /// notice hold stay: the resize's turn and each frame after it post nothing from the pane views, and the landing
    /// posts once for each.
    @Test func aWindowResizeThatCarriesTheKeySpringKeepsTheHoldToTheLanding() throws {
        let rig = Rig()
        defer { rig.window.closeAfterTest() }
        let screen = try rig.screen
        let chain = try rig.chain("p2")
        let held = Array(chain.dropLast())
        let page = try #require(rig.provider.views["p2"])
        let readers = try #require(page.host.enclosingFrameNoticeReaders)
        readers.add(page.host) {}
        defer { readers.remove(page.host) }
        let notices = Notices(watching: held)
        defer { notices.stop() }
        #expect(PaneResize.press("p2", .left, model: rig.model, view: rig.root))
        for _ in 0..<3 { _ = rig.frame() }
        // SETUP: the press is on its spring.
        try #require(screen.hasMotion && screen.holdsContentForKeyResize, "SETUP: the press landed in 3 frames")

        let before = screen.frame.size
        rig.window.setContentSize(NSSize(width: 1100, height: 760))
        rig.root.layoutSubtreeIfNeeded()
        // SETUP: the resize gave the screen a new size and the spring goes on in it.
        try #require(screen.frame.size != before, "SETUP: the window resize did not resize the screen (\(screen.frame.size))")
        try #require(screen.paneFrames.values.contains { $0.rect != $0.targetRect }, "SETUP: the window resize did not carry the key spring")

        #expect(screen.holdsContentForKeyResize, "a window resize that carried the key spring ended the key hold")
        #expect(notices.total == 0, "the turn of a window resize that carried the key spring posted \(notices.total) frame notices from the pane views")
        let spring = try Self.run(rig, pane: "p2", notices: notices)
        #expect(spring.perFrame.allSatisfy { $0 == 0 }, "the frames after the window resize posted frame notices from the pane views: \(spring.perFrame)")
        for view in held {
            #expect(spring.landing[ObjectIdentifier(view)] == 1,
                    "\(type(of: view)) posted \(spring.landing[ObjectIdentifier(view)] ?? 0) frame notices at the landing after a window resize, not 1")
        }
        #expect(!screen.holdsContentForKeyResize, "the key hold outlived its landing")
    }
}

/// A window whose live resize the test sets (`NSWindow.inLiveResize` is true only while a person drags an edge).
final class KeyResizeFrameNoticeLiveResizeWindow: NSWindow {
    var isLive = false
    override var inLiveResize: Bool { isLive }
}
