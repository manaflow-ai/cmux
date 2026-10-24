import AppKit
@testable import CmuxNextBrowser
import CmuxNextDesign
@testable import CmuxNextLayout
import Testing

/// A link clicked in a lone agent chat (Leo 2026-10-21, screenshots): the chat docks left in a new
/// column and the link's tab stays in the chat's old pane, now right of it
/// (`AgentBesidePlacement`). The chat must stay put, its frame set once to its final width, with
/// no entrance replayed; only the pane with the new tab moves, sliding in from the right edge.
/// Frames step at a fixed 120 Hz dt, so every assertion is about frame N, not wall time.
@MainActor
struct ChatDockLinkSplitMotionTests {
    final class Panes: LayoutPaneContentProvider {
        /// When set, the link's pane holds a Chromium page's host view (`CEFHostView`).
        let pages: Bool
        private(set) var page: CEFHostView?
        init(pages: Bool = false) { self.pages = pages }
        func makeContentView(for pane: PaneID) -> NSView {
            guard pages, pane == ChatDockLinkSplitMotionTests.anchor else { return NSView() }
            let page = CEFHostView(frame: .zero)
            self.page = page
            return page
        }
    }

    static let dt = 1.0 / 120
    /// The lone chat's pane; it keeps the link's tab and ends right of the dock.
    static let anchor: PaneID = "anchor"
    /// The new left dock the chat moves into.
    static let dock: PaneID = "dock"

    static let lone = ScreenLayout.columns([LayoutColumn(id: "c1", width: 1, root: .leaf(anchor))])
    static let docked = ScreenLayout.columns([
        LayoutColumn(id: "d", width: 0.5, root: .leaf(dock), dock: DockColumn(edge: .left, role: .agentChat)),
        LayoutColumn(id: "c1", width: 1, root: .leaf(anchor)),
    ])

    final class Screen {
        let provider: Panes
        let model: LayoutModel
        let root: LayoutRootView
        let window: NSWindow

        init(pages: Bool = false) {
            provider = Panes(pages: pages)
            model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: ChatDockLinkSplitMotionTests.lone)],
                                activeScreenID: "s", focusedPane: ChatDockLinkSplitMotionTests.anchor)
            root = LayoutRootView(model: model, contentProvider: provider)
            // Pins the pane springs on: the shared settings stay untouched.
            root.context.reduceMotionOverride = false
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: true)
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
            guard !link.isHidden else { return }
            let shown = Self.shown(link), expected = Self.expectedShown(link, in: view)
            if !Self.sameX(shown, expected) {
                wrong.append(String(format: "%@ x %.1f w %.1f: shows %.1f...%.1f, strip %.1f...%.1f", label, link.frame.minX,
                                    link.frame.width, shown.minX, shown.maxX, expected.minX, expected.maxX))
            }
        }
        for frame in 1...120 {
            screen.step()
            check("land \(frame)")
        }
        #expect(Self.sameX(Self.shown(link), link.bounds), "the landed pane is masked: \(Self.shown(link)) of \(link.bounds)")

        // A divider drag's resize: the chat's dock narrows, the pane widens to the left.
        let narrower = ScreenLayout.columns([
            LayoutColumn(id: "d", width: 0.3, root: .leaf(Self.dock), dock: DockColumn(edge: .left, role: .agentChat)),
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
        let screen = Screen(pages: true)
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
