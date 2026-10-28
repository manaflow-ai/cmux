import AppKit
@testable import CmuxNextBrowser
import CmuxNextDesign
@testable import CmuxNextLayout
@testable import CmuxNextTerminal
import CmuxNextWakeups
import Testing

/// A link clicked in a lone agent chat (Leo 2026-10-21, screenshots): the chat docks left in a new
/// column and the link's tab stays in the chat's old pane, now right of it
/// (`AgentBesidePlacement`). The chat must stay put, its frame set once to its final width, with
/// no entrance replayed; only the pane with the new tab moves, sliding in from the right edge.
/// Frames step at a fixed 120 Hz dt, so every assertion is about frame N, not wall time.
@MainActor
struct ChatDockLinkSplitMotionTests {
    /// What the link's pane holds.
    enum Content {
        case plain
        /// A Chromium page's host view (`CEFHostView`).
        case page
        /// A real terminal: a `TerminalSession` with a libghostty surface, the view the app puts in a
        /// terminal pane, fed by a recording IO instead of a PTY.
        case terminal
    }

    final class Panes: LayoutPaneContentProvider {
        let content: Content
        private(set) var page: CEFHostView?
        private(set) var terminal: TerminalSession?
        let io = GridRecordingTerminalIO()
        init(_ content: Content = .plain) { self.content = content }
        func makeContentView(for pane: PaneID) -> NSView {
            guard pane == ChatDockLinkSplitMotionTests.anchor else { return NSView() }
            switch content {
            case .plain:
                return NSView()
            case .page:
                let page = CEFHostView(frame: .zero)
                self.page = page
                return page
            case .terminal:
                GhosttyRuntime.startedForTests()
                let session = TerminalSession(io: io, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
                terminal = session
                return session.view
            }
        }
    }

    static let dt = 1.0 / 120
    /// The lone chat's pane; it keeps the link's tab and ends right of the dock.
    static let anchor: PaneID = "anchor"
    /// The new left dock the chat moves into.
    static let dock: PaneID = "dock"
    /// The dock's column, whose edge is the divider a person drags.
    static let dockColumn: ColumnID = "d"

    static let lone = ScreenLayout.columns([LayoutColumn(id: "c1", width: 1, root: .leaf(anchor))])
    static let docked = ScreenLayout.columns([
        LayoutColumn(id: dockColumn, width: 0.5, root: .leaf(dock), dock: DockColumn(edge: .left, role: .agentChat)),
        LayoutColumn(id: "c1", width: 1, root: .leaf(anchor)),
    ])

    final class Screen {
        let provider: Panes
        let model: LayoutModel
        let root: LayoutRootView
        let window: NSWindow

        init(_ content: Content = .plain) {
            _ = NSApplication.shared
            provider = Panes(content)
            model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: ChatDockLinkSplitMotionTests.lone)],
                                activeScreenID: "s", focusedPane: ChatDockLinkSplitMotionTests.anchor)
            root = LayoutRootView(model: model, contentProvider: provider, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
            // Pins the pane springs on: the shared settings stay untouched.
            root.context.reduceMotionOverride = false
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            window.contentView = root
            root.layoutSubtreeIfNeeded()
            // The test is the clock: the display link never ticks.
            root.driver.isManual = true
        }

        func show(_ layout: ScreenLayout) {
            model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: layout)])
            root.syncWithModel()
        }

        func host(_ pane: PaneID) -> PaneHostView? { root.context.hosts[pane] }
        var screen: ScreenContentView? { root.screenViews["s"] }
        func step() { _ = root.advanceFrame(ChatDockLinkSplitMotionTests.dt) }

        func close() {
            provider.io.finish()
            window.close()
        }

        /// A real drag of the docked chat's edge, the divider between the chat and the right pane,
        /// through the handle's drag events: `moves` pointer moves to `dx` points from the edge, one
        /// 120 Hz frame each, then the release and the spring it starts, stepped until nothing moves.
        /// `check` runs after every frame.
        func dragDockEdge(by dx: CGFloat, moves: Int = 30, check: (String) -> Void) throws {
            let view = try #require(screen)
            let edge = try #require(view.geometry.columns[ChatDockLinkSplitMotionTests.dockColumn])
            let kind = DividerHandleView.Kind.columnEdge(ChatDockLinkSplitMotionTests.dockColumn)
            let start = CGPoint(x: edge.maxX + root.context.style.stripGap / 2, y: edge.midY)
            func window(_ x: CGFloat) -> NSPoint { view.convert(CGPoint(x: x, y: start.y), to: nil) }
            view.handleDrag(kind: kind, event: .began(window(start.x)))
            for move in 1...moves {
                view.handleDrag(kind: kind, event: .moved(window(start.x + dx * CGFloat(move) / CGFloat(moves)), time: CACurrentMediaTime()))
                root.syncWithModel()
                step()
                root.layoutSubtreeIfNeeded()
                check("drag \(move)")
            }
            view.handleDrag(kind: kind, event: .ended(window(start.x + dx), time: CACurrentMediaTime()))
            root.syncWithModel()
            root.layoutSubtreeIfNeeded()
            check("release 0")
            var frames = 0
            while frames < 240, root.advanceFrame(ChatDockLinkSplitMotionTests.dt) {
                root.layoutSubtreeIfNeeded()
                frames += 1
                check("release \(frames)")
            }
        }
    }

    /// The part of `host` the strip shows (own coordinates): its bounds cut by the strip container's
    /// clip and its own mask; all of it with neither.
    static func shown(_ host: PaneHostView) -> CGRect { host.stripShownRect }

    /// The part of `host` (own coordinates) inside the strip's clip range: the strip shows a pane
    /// right of a left dock from the dock's edge to the strip's right edge, whatever its x.
    static func expectedShown(_ host: PaneHostView, in screen: ScreenContentView) -> CGRect {
        let g = screen.geometry, frame = host.frame
        let minX = max(0, g.clipMinX - frame.minX), maxX = min(frame.width, max(minX, g.clipMaxX - frame.minX))
        return CGRect(x: minX, y: 0, width: maxX - minX, height: frame.height)
    }

    static func sameX(_ a: CGRect, _ b: CGRect) -> Bool { abs(a.minX - b.minX) <= 1 && abs(a.width - b.width) <= 1 }

    /// Why `host`'s strip mask is off its part inside the strip, or nil when it is right (or hidden).
    static func maskError(_ host: PaneHostView, in screen: ScreenContentView, _ label: String) -> String? {
        guard !host.isHidden else { return nil }
        let shown = Self.shown(host), expected = Self.expectedShown(host, in: screen)
        guard !sameX(shown, expected) else { return nil }
        return String(format: "%@ x %.1f w %.1f: shows %.1f...%.1f, strip %.1f...%.1f", label, host.frame.minX,
                      host.frame.width, shown.minX, shown.maxX, expected.minX, expected.maxX)
    }

    /// Why the Chromium page in `host` is off its part inside the strip, or nil when it is right: the
    /// page is a child window no layer mask reaches, so its clip shape (`cmuxClipPath`, which carries
    /// the strip mask) must be nil or the page's part inside the strip, and no occlusion hole may
    /// cover a page the strip shows.
    static func pageError(_ page: CEFHostView, in host: PaneHostView, screen: ScreenContentView, _ label: String) -> String? {
        guard !host.isHidden, page.bounds.width > 1 else { return nil }
        let part = page.bounds.intersection(page.convert(Self.expectedShown(host, in: screen), from: host))
        guard part.width > 1 else { return nil }
        let holes = (page.cmuxOcclusionRects() as? [NSValue])?.map(\.rectValue) ?? []
        if holes.contains(where: { $0.contains(part.insetBy(dx: 1, dy: 1)) }) {
            return "\(label): page \(page.bounds) hidden by holes \(holes), strip shows \(part)"
        }
        let clip = page.cmuxClipPath()?.bounds ?? page.bounds
        guard abs(clip.minX - part.minX) > 1 || abs(clip.width - part.width) > 1 else { return nil }
        return String(format: "%@: page clip %.1f...%.1f, strip shows %.1f...%.1f of %.1f", label, clip.minX, clip.maxX,
                      part.minX, part.maxX, page.bounds.width)
    }

    @Test func theChatStaysAndOnlyTheLinksPaneSlidesInFromTheRight() throws {
        let screen = Screen()
        // The app's link placement names the chat's pane before the chat docks.
        screen.model.handOffContent(of: Self.anchor)
        screen.show(Self.docked)
        let chat = try #require(screen.host(Self.dock)), link = try #require(screen.host(Self.anchor))
        let clipMaxX = try #require(screen.screen?.geometry.clipMaxX)
        var chatFrames: [CGRect] = [chat.frame], chatAlphas: [CGFloat] = [chat.alphaValue]
        var linkFrames: [CGRect] = [link.frame]
        for _ in 1...120 {
            screen.step()
            chatFrames.append(chat.frame)
            chatAlphas.append(chat.alphaValue)
            linkFrames.append(link.frame)
        }
        let rest = try #require(chatFrames.last), linkRest = try #require(linkFrames.last)
        print("chat-dock link split (120 Hz; chat minX width | link minX width):\n" + zip(chatFrames, linkFrames).enumerated()
            .map { String(format: "%d\t%6.1f %6.1f | %6.1f %6.1f", $0, $1.0.minX, $1.0.width, $1.1.minX, $1.1.width) }
            .joined(separator: "\n"))

        // The chat: one frame, its final one, from the change on; opaque throughout (no entrance).
        #expect(chatFrames.allSatisfy { $0 == rest }, "the chat's pane moved after the link opened: \(chatFrames.map(\.width))")
        #expect(rest.width > 1 && rest.minX <= 1, "the chat does not rest in its left dock: \(rest)")
        #expect(chatAlphas.allSatisfy { $0 == 1 }, "the chat's pane faded in again: \(chatAlphas)")

        // The link's pane: its final width from the first frame, coming from the right edge, never
        // going back, and resting right of the chat.
        #expect(linkFrames.allSatisfy { abs($0.width - linkRest.width) <= 1 }, "the link's pane resized while it came in")
        let first = try #require(linkFrames.first)
        #expect(first.minX >= clipMaxX - 1, "the link's pane did not start past the right edge: \(first.minX) < \(clipMaxX)")
        let xs = linkFrames.map(\.minX)
        #expect(zip(xs, xs.dropFirst()).allSatisfy { $1 <= $0 + 0.5 }, "the link's pane went back right: \(xs)")
        #expect(linkRest.minX >= rest.maxX - 1, "the link's pane rests over the chat: \(linkRest) vs \(rest)")
    }

    /// A folder opened from a lone chat (or a person's new tab from it) docks the chat through
    /// `ChatColumnPlacement.route`, which hands the chat's content over the same way: the hint is
    /// pending while the move runs, stays when the move lands, and is dropped when it fails, so a
    /// later split still plays as a split.
    @Test func aHandOffDuringAMoveLastsOnlyWhenTheMoveLands() {
        let screen = Screen()
        var during: PaneID?
        var finish: (@MainActor (Bool) -> Void)?
        screen.model.handOffContent(of: Self.anchor) { done in
            during = screen.model.pendingContentHandoff
            finish = done
        }
        #expect(during == Self.anchor, "the hint was not pending while the chat docked")
        finish?(false)
        #expect(screen.model.pendingContentHandoff == nil, "a failed dock left the hint for the next split")

        screen.model.handOffContent(of: Self.anchor) { done in done(true) }
        #expect(screen.model.pendingContentHandoff == Self.anchor, "a dock that landed dropped the hint before it played")
    }

    /// The dock that lands through it plays as the hand-off: the chat keeps one frame.
    @Test func aFolderDockThroughTheMoveKeepsTheChatPut() throws {
        let screen = Screen()
        screen.model.handOffContent(of: Self.anchor) { done in
            screen.show(Self.docked)
            done(true)
        }
        let chat = try #require(screen.host(Self.dock))
        var frames: [CGRect] = [chat.frame]
        for _ in 1...60 {
            screen.step()
            frames.append(chat.frame)
        }
        let rest = try #require(frames.last)
        #expect(frames.allSatisfy { $0 == rest }, "the chat's pane moved when a folder docked it: \(frames.map(\.width))")
    }

    /// Right side panes (Leo 2026-10-24: "it didn't even show this initially. Like ... I had to
    /// drag it out to resize, and ... as I drag, I see this small sliver opening up from the
    /// center"): beside a docked chat, the strip clip of a pane at x X0 and width W was cut to
    /// 0...W - X0 (a screen-space clip met with a local one), so it was hidden while it slid in
    /// and showed a sliver from its middle when resized. Every frame the pane shows exactly its
    /// part inside the strip, and at rest all of it, after the link lands and after a resize.
    @Test func aRightPaneBesideADockedChatShowsItsPartInsideTheStripOnEveryFrame() throws {
        let screen = Screen()
        screen.model.handOffContent(of: Self.anchor)
        screen.show(Self.docked)
        let link = try #require(screen.host(Self.anchor)), view = try #require(screen.screen)
        var wrong: [String] = []
        func check(_ label: String) {
            if let error = Self.maskError(link, in: view, label) { wrong.append(error) }
        }
        for frame in 1...120 {
            screen.step()
            check("land \(frame)")
        }
        #expect(Self.sameX(Self.shown(link), link.bounds), "the landed pane is masked: \(Self.shown(link)) of \(link.bounds)")

        // A divider drag's resize: the chat's dock narrows, the pane widens to the left.
        let narrower = ScreenLayout.columns([
            LayoutColumn(id: Self.dockColumn, width: 0.3, root: .leaf(Self.dock), dock: DockColumn(edge: .left, role: .agentChat)),
            LayoutColumn(id: "c1", width: 1, root: .leaf(Self.anchor)),
        ])
        screen.show(narrower)
        check("resize 0")
        for frame in 1...120 {
            screen.step()
            check("resize \(frame)")
        }
        #expect(Self.sameX(Self.shown(link), link.bounds), "the resized pane is masked: \(Self.shown(link)) of \(link.bounds)")
        #expect(wrong.isEmpty, "the right pane's mask is off the strip: \(wrong.prefix(8).joined(separator: "; "))")
    }

    /// The same pane holding a Chromium page: the page is a child window that no layer mask
    /// reaches, so its clip shape (`cmuxClipPath`, which carries the strip mask) must show the
    /// whole page once it lands, not a sliver.
    @Test func aRightPageBesideADockedChatShowsTheWholePage() throws {
        let screen = Screen(.page)
        screen.model.handOffContent(of: Self.anchor)
        screen.show(Self.docked)
        for _ in 1...120 { screen.step() }
        screen.root.layoutSubtreeIfNeeded()
        let page = try #require(screen.provider.page)
        #expect(page.bounds.width > 100, "the page has no width: \(page.bounds)")
        // A page clipped away entirely has no clip path and one hole over all of it.
        let holes = (page.cmuxOcclusionRects() as? [NSValue])?.map(\.rectValue) ?? []
        #expect(!holes.contains(page.bounds), "the landed page is hidden: holes \(holes)")
        let shown = page.cmuxClipPath()?.bounds ?? page.bounds
        #expect(abs(shown.width - page.bounds.width) < 1, "the landed page shows \(shown) of \(page.bounds)")
    }

    /// The page again, through a real drag of the chat's edge (Leo 2026-10-24: "I had to drag it out
    /// to resize, and ... as I drag, I see this small sliver opening up from the center"): narrowed,
    /// widened back, and through each release's spring, the page shows its part inside the strip on
    /// every frame and all of it at rest.
    @Test func aRightPageBesideADockedChatShowsTheWholePageWhileTheChatsEdgeIsDragged() throws {
        let screen = Screen(.page)
        defer { screen.close() }
        screen.model.handOffContent(of: Self.anchor)
        screen.show(Self.docked)
        for _ in 1...120 { screen.step() }
        screen.root.layoutSubtreeIfNeeded()
        let link = try #require(screen.host(Self.anchor)), view = try #require(screen.screen)
        let page = try #require(screen.provider.page)
        var wrong: [String] = [], checked = 0
        func check(_ label: String) {
            checked += 1
            if let error = Self.maskError(link, in: view, label) { wrong.append(error) }
            if let error = Self.pageError(page, in: link, screen: view, label) { wrong.append(error) }
        }
        let before = link.frame
        try screen.dragDockEdge(by: -240) { check("narrow \($0)") }
        #expect(link.frame.width > before.width + 100, "the drag did not widen the page's pane: \(before) -> \(link.frame)")
        let widened = link.frame
        try screen.dragDockEdge(by: 120) { check("widen \($0)") }
        #expect(link.frame.width < widened.width - 50, "the drag back did not narrow the page's pane: \(widened) -> \(link.frame)")
        #expect(checked > 60, "only \(checked) frames were checked")
        let holes = (page.cmuxOcclusionRects() as? [NSValue])?.map(\.rectValue) ?? []
        #expect(!holes.contains(page.bounds), "the dragged page is hidden: holes \(holes)")
        let shown = page.cmuxClipPath()?.bounds ?? page.bounds
        #expect(abs(shown.width - page.bounds.width) < 1, "the dragged page shows \(shown) of \(page.bounds)")
        #expect(wrong.isEmpty, "the page is off the strip: \(wrong.prefix(8).joined(separator: "; "))")
    }

    /// The same pane holding a real terminal (a `TerminalSession` with a libghostty surface): the
    /// strip mask is on the `PaneHostView` whatever it holds, so a terminal beside a docked chat was
    /// hidden while it slid in and a sliver while its edge was dragged, like the page. It shows its
    /// part inside the strip on every frame of the landing and of a real drag, and all of it at rest.
    @Test func aRightTerminalBesideADockedChatShowsItsPartInsideTheStripOnEveryFrame() throws {
        let screen = Screen(.terminal)
        defer { screen.close() }
        screen.model.handOffContent(of: Self.anchor)
        screen.show(Self.docked)
        let link = try #require(screen.host(Self.anchor)), view = try #require(screen.screen)
        let session = try #require(screen.provider.terminal, "the link's pane holds no terminal")
        try #require(session.surfaceView.surface != nil, "libghostty created no surface")
        #expect(session.view.isDescendant(of: link), "the terminal is not in the link's pane")
        var wrong: [String] = []
        func check(_ label: String) {
            if let error = Self.maskError(link, in: view, label) { wrong.append(error) }
        }
        for frame in 1...120 {
            screen.step()
            check("land \(frame)")
        }
        screen.root.layoutSubtreeIfNeeded()
        #expect(Self.sameX(Self.shown(link), link.bounds), "the landed terminal is masked: \(Self.shown(link)) of \(link.bounds)")
        try screen.dragDockEdge(by: -240) { check("narrow \($0)") }
        try screen.dragDockEdge(by: 120) { check("widen \($0)") }
        #expect(Self.sameX(Self.shown(link), link.bounds), "the dragged terminal is masked: \(Self.shown(link)) of \(link.bounds)")
        #expect(session.view.frame.width > link.bounds.width / 2, "the terminal does not fill its pane: \(session.view.frame)")
        #expect(wrong.isEmpty, "the terminal's pane mask is off the strip: \(wrong.prefix(8).joined(separator: "; "))")
    }

    /// The strip's clip beside a docked chat is layer structure: the link's pane
    /// sits in the strip container, whose frame is the strip's range and whose layer masks to its
    /// bounds; the host carries no mask, and the chat's pane is a sibling stacked above the container.
    @Test func theStripContainerClipsAHostAtItsOwnPlace() throws {
        let screen = Screen()
        screen.show(Self.docked)
        for _ in 1...120 { screen.step() }
        let link = try #require(screen.host(Self.anchor)), chat = try #require(screen.host(Self.dock))
        let view = try #require(screen.screen)
        let frame = link.frame
        #expect(frame.minX > 100, "the pane is not right of the dock: \(frame)")
        #expect(link.superview === view.stripContainer, "the strip pane is not in the strip container")
        #expect(chat.superview === view, "the docked pane is not in the screen above the strip container")
        #expect(link.layer?.mask == nil, "the strip pane carries a mask: \(Self.shown(link))")
        #expect(view.stripContainer.layer?.masksToBounds == true, "the strip container does not clip")
        let g = view.geometry
        #expect(abs(view.stripContainer.frame.minX - g.clipMinX) < 0.5 && abs(view.stripContainer.frame.maxX - g.clipMaxX) < 0.5,
                "the strip container is not the strip's range: \(view.stripContainer.frame), strip \(g.clipMinX)...\(g.clipMaxX)")
        // The container's coordinates are the screen's: the host's frame is where it shows.
        #expect(view.convert(link.bounds, from: link) == frame, "the host's frame is off the screen's coordinates")
        #expect(Self.sameX(Self.shown(link), Self.expectedShown(link, in: view)),
                "the host shows \(Self.shown(link)), the strip \(Self.expectedShown(link, in: view))")
    }
}
