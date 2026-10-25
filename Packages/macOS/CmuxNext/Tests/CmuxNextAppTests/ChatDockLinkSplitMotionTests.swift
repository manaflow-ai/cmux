import AppKit
@testable import CmuxNextAgentPane
@testable import CmuxNextBrowser
import CmuxNextDesign
@testable import CmuxNextLayout
import CmuxNextPagesTestSupport
@testable import CmuxNextTerminal
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
        /// An agent chat: the app's `AgentPaneView` on the shared page host, shown in Chromium (the
        /// default, `agent.chromium`). Its page's view holds a `CEFHostView` filling it, as a CEF tab's
        /// content view does, so the page's clip shape is read through the chat's own views.
        case chat
    }

    private actor NoChatHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    /// The agent page the chat loads (the page host registers its root once per process, so it is
    /// made once and never deleted).
    static let chatPage: URL? = {
        let directory = FileManager.default.temporaryDirectory.appending(path: "right-split-chat-\(UUID().uuidString)")
        let file = directory.appending(path: "index.html")
        guard (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil,
              (try? Data("<html><body><textarea></textarea></body></html>".utf8).write(to: file)) != nil else { return nil }
        return file
    }()

    final class Panes: LayoutPaneContentProvider {
        let content: Content
        private(set) var page: CEFHostView?
        private(set) var terminal: TerminalSession?
        private(set) var chat: AgentPaneView?
        private var hosting: FakeChromiumHosting?
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
                _ = GhosttyRuntime.shared
                let session = TerminalSession(io: io)
                terminal = session
                return session.view
            case .chat:
                let hosting = FakeChromiumHosting()
                hosting.onMade = { [weak self] made in
                    let page = CEFHostView(frame: made.contentView.bounds)
                    page.autoresizingMask = [.width, .height]
                    made.contentView.addSubview(page)
                    self?.page = page
                }
                self.hosting = hosting
                guard let file = ChatDockLinkSplitMotionTests.chatPage,
                      let chat = AgentPaneView(model: AgentPaneModel(host: NoChatHost()), source: .bundled(file), pageHost: true,
                                               chromium: hosting) else { return NSView() }
                self.chat = chat
                return chat
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
            root = LayoutRootView(model: model, contentProvider: provider)
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
            provider.chat?.close()
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
                view.handleDrag(kind: kind, event: .moved(window(start.x + dx * CGFloat(move) / CGFloat(moves))))
                root.syncWithModel()
                step()
                root.layoutSubtreeIfNeeded()
                check("drag \(move)")
            }
            view.handleDrag(kind: kind, event: .ended(window(start.x + dx)))
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

    /// The part of `host` its strip mask shows (own coordinates): all of it with no mask.
    static func shown(_ host: PaneHostView) -> CGRect { host.layer?.mask?.frame ?? host.bounds }

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

    /// Why `host` shows nothing, or a part starting inside it, while its leading part is inside the
    /// strip, or nil when it does not: the pane hidden while it slid in, then "a small sliver opening
    /// up from the center" (Leo 2026-10-24).
    static func centreError(_ host: PaneHostView, in screen: ScreenContentView, _ label: String) -> String? {
        guard !host.isHidden else { return nil }
        let shown = Self.shown(host), expected = Self.expectedShown(host, in: screen)
        guard expected.minX < 0.5, expected.width > 1, shown.minX > 0.5 || shown.width < 1 else { return nil }
        return String(format: "%@: shows %.1f...%.1f of a pane whose 0...%.1f is inside the strip", label, shown.minX,
                      shown.maxX, expected.maxX)
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

    /// The whole right split (Leo 2026-10-24: "obviously it's not JUST browsers terminals are in that
    /// same right area split the whole right side got fucked up at some point"): a terminal, a
    /// Chromium page and an agent chat, each in the pane that opens right of a docked chat. On every
    /// frame of the open spring, its landing and a real drag of the chat's edge (each move, the
    /// release and its spring to rest):
    /// - the pane's content is the pane's final size from the open's first frame (the strip moves the
    ///   pane; nothing grows),
    /// - what shows of the pane is its part inside the strip, from its leading edge to the strip's
    ///   right edge while it slides in, never nothing and never a part starting inside it,
    /// - a Chromium page (the browser's, the chat's) clips to that same part with no hole over it,
    /// and at rest the pane shows all of itself and its content fills it.
    @Test func aRightTerminalOpensAtItsFullSizeFromTheRightEdge() async throws { try await openRightSplit(.terminal) }

    @Test func aRightPageOpensAtItsFullSizeFromTheRightEdge() async throws { try await openRightSplit(.page) }

    @Test func aRightChatOpensAtItsFullSizeFromTheRightEdge() async throws { try await openRightSplit(.chat) }

    private func openRightSplit(_ kind: Content) async throws {
        let screen = Screen(kind)
        defer { screen.close() }
        let link = try #require(screen.host(Self.anchor)), view = try #require(screen.screen)
        let clipMaxX = try #require(screen.screen?.geometry.clipMaxX)
        switch kind {
        case .terminal:
            let session = try #require(screen.provider.terminal, "the pane holds no terminal")
            try #require(session.surfaceView.surface != nil, "libghostty created no surface")
        case .chat:
            let chat = try #require(screen.provider.chat, "the agent page is missing")
            // The page host makes the chat's Chromium page asynchronously, as in the app.
            let deadline = Date().addingTimeInterval(10)
            while chat.chromiumPage == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
            try #require(chat.chromiumPage != nil, "the chat never showed in Chromium")
        case .page, .plain:
            break
        }
        let page = screen.provider.page
        if kind == .page || kind == .chat { try #require(page != nil, "the pane shows no Chromium page") }
        #expect(page?.isDescendant(of: link) ?? true, "the page is not in the right pane")
        let content = link.content

        var wrong: [String] = []
        func check(_ label: String) {
            if let error = Self.maskError(link, in: view, label) { wrong.append(error) }
            if let error = Self.centreError(link, in: view, label) { wrong.append(error) }
            if let page, let error = Self.pageError(page, in: link, screen: view, label) { wrong.append(error) }
        }
        func fillsItsPane(_ label: String) {
            #expect(Self.sameX(Self.shown(link), link.bounds), "\(label): the pane is masked: \(Self.shown(link)) of \(link.bounds)")
            #expect(content.frame.size == link.contentRect.size, "\(label): the content \(content.frame) does not fill \(link.contentRect)")
            guard let page else { return }
            let holes = (page.cmuxOcclusionRects() as? [NSValue])?.map(\.rectValue) ?? []
            #expect(page.bounds.width > 100 && !holes.contains(page.bounds), "\(label): the page is hidden: holes \(holes)")
            let clip = page.cmuxClipPath()?.bounds ?? page.bounds
            #expect(abs(clip.width - page.bounds.width) < 1, "\(label): the page shows \(clip) of \(page.bounds)")
        }

        // The open: a lone chat docks left and the pane slides in from the right edge.
        screen.model.handOffContent(of: Self.anchor)
        screen.show(Self.docked)
        screen.root.layoutSubtreeIfNeeded()
        var frames: [CGRect] = [], sizes: [CGSize] = [], pageSizes: [CGSize] = [], partly = 0
        func record(_ label: String) {
            check(label)
            frames.append(link.frame)
            sizes.append(content.frame.size)
            if let page { pageSizes.append(page.bounds.size) }
            let part = Self.expectedShown(link, in: view).width
            if part > 1, part < link.frame.width - 1 { partly += 1 }
        }
        record("open 0")
        for frame in 1...120 {
            screen.step()
            screen.root.layoutSubtreeIfNeeded()
            record("open \(frame)")
        }
        let first = try #require(frames.first), rest = try #require(frames.last)
        #expect(first.minX >= clipMaxX - 1, "the pane did not start at the strip's right edge: \(first.minX) < \(clipMaxX)")
        #expect(frames.allSatisfy { abs($0.width - rest.width) <= 1 }, "the pane resized while it opened: \(frames.map(\.width))")
        #expect(sizes.allSatisfy { $0 == link.contentRect.size },
                "the content was not its final size \(link.contentRect.size) from the first frame: \(Set(sizes.map(\.width)))")
        #expect(pageSizes.allSatisfy { $0 == pageSizes.last }, "the page resized while it opened: \(Set(pageSizes.map(\.width)))")
        #expect(partly > 3, "the pane never showed partly inside the strip while it slid in (\(partly) frames)")
        fillsItsPane("landed")

        // A real drag of the chat's edge: narrower (the pane widens to the left), then back.
        let before = link.frame
        try screen.dragDockEdge(by: -240) { check("narrow \($0)") }
        #expect(link.frame.width > before.width + 100, "the drag did not widen the pane: \(before) -> \(link.frame)")
        fillsItsPane("narrowed")
        let widened = link.frame
        try screen.dragDockEdge(by: 120) { check("widen \($0)") }
        #expect(link.frame.width < widened.width - 50, "the drag back did not narrow the pane: \(widened) -> \(link.frame)")
        fillsItsPane("widened")
        let firstWrong = wrong.prefix(8).joined(separator: "; ")
        #expect(wrong.isEmpty, "\(kind): the right pane is off its part inside the strip on \(wrong.count) frames: \(firstWrong)")
    }

    /// `clipToStrip` on a host away from the screen's origin: a strip clip and a pane in front, in
    /// the screen's coordinates, cut the host's mask where they meet it in its own coordinates.
    @Test func aStripClipMeetsAHostAtItsOwnPlace() throws {
        let screen = Screen()
        screen.show(Self.docked)
        for _ in 1...120 { screen.step() }
        let link = try #require(screen.host(Self.anchor)), view = try #require(screen.screen)
        let frame = link.frame
        #expect(frame.minX > 100, "the pane is not right of the dock: \(frame)")
        // All of the host inside the clip: no mask.
        view.clipToStrip(link, scrolls: true, clip: frame.insetBy(dx: -50, dy: -50), above: [:], force: true)
        #expect(link.layer?.mask == nil, "a clip around the whole host masked it: \(Self.shown(link))")
        // The clip ends 100 pt before the host's right edge: the mask is the host's left part.
        let clip = CGRect(x: 0, y: frame.minY, width: frame.maxX - 100, height: frame.height)
        view.clipToStrip(link, scrolls: true, clip: clip, above: [:], force: true)
        #expect(Self.sameX(Self.shown(link), CGRect(x: 0, y: 0, width: frame.width - 100, height: frame.height)),
                "the mask is not the host's left part: \(Self.shown(link)) of \(frame)")
        // A pane in front over the host's left 60 pt narrows it from the left.
        let cover = CGRect(x: frame.minX - 20, y: frame.minY, width: 80, height: frame.height)
        view.clipToStrip(link, scrolls: true, clip: clip, above: [ObjectIdentifier(link): [cover]], force: true)
        #expect(Self.sameX(Self.shown(link), CGRect(x: 60, y: 0, width: frame.width - 160, height: frame.height)),
                "the cover did not cut the host's left: \(Self.shown(link)) of \(frame)")
    }
}
