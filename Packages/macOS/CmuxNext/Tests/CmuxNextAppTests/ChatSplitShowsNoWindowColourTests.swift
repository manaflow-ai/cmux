import AppKit
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextLayout
import CmuxNextSettings
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Foundation
import Testing

/// SPLIT OPEN CHAT (Lawrence: during a split "the gap shows the page colour ... no blank or stale-colour frames, no
/// flash at the end"). Split Down on a pane that shows a chat: the chat takes its rest height on the spring's first
/// frame (Leo 2026-11-05: it lays out once, at the start), and its pane comes to that height over the spring. Between
/// the chat's bottom edge and the pane's, nothing painted: the WINDOW colour showed there for 2 to 7 frames at 120 Hz
/// (films head-chat-1..3 of hold f7a, aws-m4pro-7; trace head-chat-1: pane 658 pt high, chat 490 pt). Chromium shows a
/// resized page's old content on the page's own ground until the new frame comes; so does a pane here: in each frame
/// of the split, the part of the old pane its held chat does not cover shows the chat's own ground, and so does the
/// new pane's rect.
///
/// The held chat has its tabs with it (`tabs.barPosition` bottom: the strip is at the chat's bottom edge, in the middle
/// of the pane that the split still halves; vertical tabs: the list is at its leading edge). The ground is measured from
/// where the chat is, not from the pane's edges (review of #40665): below a bottom strip the pane shows the chat's
/// ground down to its own bottom edge, and the strip and the list show what they show at rest, never the chat's ground
/// behind the tabs.
///
/// Driven as the layout drives a spring (the rest size, the rest offset, the spring flag, then a frame per display
/// frame), on real panes (`PaneContentView` with its strip, showing an `AgentPaneView`), and read from the pixels of
/// the layer tree, as `AgentPaneNewPaneGroundTests` reads them.
@MainActor @Suite(.serialized, .closesItsWindows)
struct ChatSplitShowsNoWindowColourTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    /// The screen's coordinates, as the layout's: the origin is the top left corner.
    private final class Screen: NSView { nonisolated override var isFlipped: Bool { true } }

    /// The window colour: what shows where no pane paints (the film kit's FF00FF).
    static let window = ThemeRGB(hex: 0xFF00FF)
    /// The chat's own ground (`appearance.surfaces`; the film kit's 0000FF).
    static let chatGround = ThemeRGB(hex: 0x0000FF)

    static func rgb(_ color: ThemeRGB) -> [Int] {
        [color.red, color.green, color.blue].map { Int(($0 * 255).rounded()) }
    }

    /// The pixel at `point` (the screen's coordinates: the origin is the top left corner) of `root`'s layer tree as it
    /// would draw now. `root` is not flipped and has the screen's size.
    static func pixel(of root: NSView, at point: CGPoint) throws -> [Int] {
        root.layoutSubtreeIfNeeded()
        root.displayIfNeeded()
        CATransaction.flush()
        let (width, height) = (Int(root.bounds.width), Int(root.bounds.height))
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                             space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        try #require(root.layer).render(in: context)
        let data = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        // A bitmap context's first row is the image's top.
        let offset = (min(height - 1, max(0, Int(point.y))) * width + min(width - 1, max(0, Int(point.x)))) * 4
        return (0..<3).map { Int(data[offset + $0]) }
    }

    /// One pane's content as the app builds it (its tab strip, at `bar`, or its vertical tab list, beside its content
    /// area) showing a chat whose own ground is ``chatGround``. The page has not drawn: the chat shows its ground, as a
    /// pane does until its page's frame.
    private func chatPane(page: URL, bar: TabBarPosition, vertical: PaneVerticalTabs?, hidesStrip: Bool = false) throws -> (content: PaneContentView, chat: AgentPaneView) {
        let reveal = LaunchReveal()
        reveal.markAllReady()
        let content = PaneContentView(stripModel: TabStripModel(tabs: [TabItem(id: TabID("chat"), title: "chat")]), reveal: reveal)
        content.barPosition = bar
        if hidesStrip || vertical != nil { content.showStrip(hidden: hidesStrip, vertical: vertical) }
        content.paneScope.setSurfaceBackgrounds(SurfaceBackgrounds(overrides: [.agentPane: SurfaceBackground(color: Self.chatGround, opacity: 1)]))
        let chat = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost()), source: .bundled(page)))
        return (content, chat)
    }

    /// The points of a pane's rect that its content area covers in a frame, away from the centre (a loading mark may
    /// draw there): `ys` are distances from the screen's top.
    private static func points(width: CGFloat, ys: [CGFloat]) -> [CGPoint] {
        ys.flatMap { y in [0.25, 0.75].map { CGPoint(x: (width * $0).rounded(), y: y.rounded()) } }
    }

    /// Split Down on a pane that shows a chat, a frame per display frame of the spring, then the landing: each point
    /// inside a pane that did not show what it must. A point of a pane's content area and of the part of the old pane
    /// that its held chat does not cover must show the chat's own ground (not only "not the window colour": another
    /// colour there is a hole too). A point of the chat's own tabs (its strip, its vertical list) must show what it
    /// showed at rest.
    private func holesInASplitDown(bar: TabBarPosition, vertical: PaneVerticalTabs? = nil) throws -> [String] {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appending(path: "chat-split-ground-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let page = directory.appending(path: "index.html")
        try Data("<html><body></body></html>".utf8).write(to: page)

        let size = CGSize(width: 800, height: 600)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.closeAfterTest() }
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        root.wantsLayer = true
        root.layer?.backgroundColor = Self.window.cgColor
        let screen = Screen(frame: root.bounds)
        root.addSubview(screen)
        window.contentView = root
        window.orderFrontRegardless()
        let ground = Self.rgb(Self.chatGround)

        // The pane that shows a chat, at rest in the whole screen.
        let old = try chatPane(page: page, bar: bar, vertical: vertical)
        defer { old.chat.close() }
        let oldHost = PaneHostView(pane: "old", content: old.content, holdsContentInMotion: { true })
        oldHost.frame = CGRect(origin: .zero, size: size)
        screen.addSubview(oldHost)
        old.content.show(old.chat)
        old.chat.applyTheme(force: true)
        root.layoutSubtreeIfNeeded()
        try #require(old.chat.superview === old.content.contentHost && !old.chat.isHiddenOrHasHiddenAncestor, "fixture: the pane does not show its chat")
        let (header, footer) = (oldHost.headerHeight, oldHost.footerHeight)
        try #require(header < 100 && footer < 100, "fixture: the pane's header is \(header) pt high and its footer \(footer) pt")
        // The width its vertical tab list takes at its leading edge; 0 with a tab strip.
        let list = old.content.contentHost.frame.minX
        if vertical != nil {
            try #require(list > 0 && list < 150, "fixture: the vertical tab list takes \(list) pt")
        } else {
            try #require(list == 0 && (bar == .top ? header > 0 && footer == 0 : header == 0 && footer > 0),
                         "fixture: tabs at the \(bar): header \(header) pt, footer \(footer) pt, list \(list) pt")
        }
        let atRest = try Self.pixel(of: root, at: CGPoint(x: 200, y: header + 150))
        try #require(atRest == ground, "fixture: the chat pane at rest shows \(atRest), not its own ground \(ground)")

        // Split Down: the old pane rests in the top half, the new pane (a chat too) in the bottom half, 1 pt apart.
        let oldRest = CGRect(x: 0, y: 0, width: size.width, height: 299)
        let newRest = CGRect(x: 0, y: 300, width: size.width, height: 300)

        // A point of the chat's own tabs where no tab draws, at rest, and what it shows there: its strip's row (the
        // strip is at the chat's top or bottom edge), or its vertical list's column below the list's rows.
        let tabsAtRest = vertical != nil ? CGPoint(x: list / 2, y: oldRest.height - 20)
            : CGPoint(x: 600, y: bar == .top ? header / 2 : size.height - footer / 2)
        let tabsShownAtRest = try Self.pixel(of: root, at: tabsAtRest)

        let new = try chatPane(page: page, bar: bar, vertical: vertical)
        defer { new.chat.close() }
        let newHost = PaneHostView(pane: "new", content: new.content, holdsContentInMotion: { true })
        newHost.frame = CGRect(x: 0, y: size.height, width: size.width, height: 0)
        screen.addSubview(newHost)
        new.content.show(new.chat)
        new.chat.applyTheme(force: true)
        try #require(new.chat.superview === new.content.contentHost, "fixture: the new pane does not show its chat")

        // The spring's first frame: each pane hears the rest it heads for and the flag, in the key's turn.
        for (host, rest) in [(oldHost, oldRest), (newHost, newRest)] {
            host.restSize = rest.size
            host.restOffset = CGVector(dx: rest.minX - host.frame.minX, dy: rest.minY - host.frame.minY)
            host.isOnLayoutSpring = true
            host.announceRest()
        }

        // Each display frame of the spring: where the divider is. The key's frame is the first one.
        var holes: [String] = []
        var bands = 0
        for divider in [600, 560, 480, 400, 340, 310, 300] as [CGFloat] {
            let oldFrame = CGRect(x: 0, y: 0, width: size.width, height: divider - 1)
            let newFrame = CGRect(x: 0, y: divider, width: size.width, height: size.height - divider)
            PaneHeldContentLandingTests.present(oldHost, at: oldFrame, rest: oldRest)
            PaneHeldContentLandingTests.present(newHost, at: newFrame, rest: newRest)
            // The old pane's chat (held at its rest height at the pane's top edge): under its header, and above its footer.
            var ys: [CGFloat] = [header + 150, oldRest.height - footer - 12]
            // The chat's own tabs, where the held chat has them: at its edges, not at the pane's.
            var tabs: [CGPoint] = vertical != nil ? [tabsAtRest]
                : [CGPoint(x: 600, y: bar == .top ? header / 2 : oldRest.height - footer / 2)]
            if oldFrame.height > oldRest.height + 8 {
                bands += 1
                // What the chat does not cover: in its middle, and at the pane's bottom edge.
                ys += [(oldRest.height + oldFrame.height) / 2, oldFrame.maxY - 4]
                if vertical != nil { tabs.append(CGPoint(x: list / 2, y: (oldRest.height + oldFrame.height) / 2)) }
            }
            // The new pane's chat (it rides its top edge at its rest height, so a strip on top shows from its first
            // frames and a strip at the bottom comes into the pane at the end).
            if newFrame.height >= header + 170 {
                ys.append(newFrame.minY + header + 150)
                if newFrame.height - 8 < newRest.height - footer - 4 { ys.append(newFrame.maxY - 8) }
            }
            for point in Self.points(width: size.width, ys: ys) {
                let shown = try Self.pixel(of: root, at: point)
                if shown != ground {
                    holes.append("divider \(Int(divider)): (\(Int(point.x)), \(Int(point.y))) in the \(point.y < divider ? "old" : "new") pane shows \(shown), not the chat's ground")
                }
            }
            for point in tabs {
                let shown = try Self.pixel(of: root, at: point)
                if shown != tabsShownAtRest {
                    holes.append("divider \(Int(divider)): (\(Int(point.x)), \(Int(point.y))) in the old pane's tabs shows \(shown), not \(tabsShownAtRest) as at rest")
                }
            }
        }
        try #require(bands >= 4, "the test no longer reaches the frames in which the old pane is taller than its held chat")

        // The landing: both panes at rest, the content let go.
        oldHost.isOnLayoutSpring = false
        newHost.isOnLayoutSpring = false
        for y in [header + 150, oldRest.height - footer - 12, newRest.minY + header + 150, newRest.maxY - footer - 8] as [CGFloat] {
            let shown = try Self.pixel(of: root, at: CGPoint(x: 200, y: y))
            if shown != ground { holes.append("at rest after the split: (200, \(Int(y))) shows \(shown), not the chat's ground") }
        }
        return holes
    }

    /// Split Right (or Split Left: `newPaneOnTheLeft`) on a pane that shows a chat with no tab strip: the person hid
    /// the pane's tab bar, or the pane has vertical tabs (`vertical`). Such a pane still reports a header as high as
    /// a strip, for its focus ring (`PaneContentView.hiddenAgentHeaderHeight`), but the chat paints those rows itself.
    /// The held chat keeps its rest width from the spring's first frame, so the old pane is wider than its chat for
    /// the frames of the spring: each point of that part must show the chat's own ground, in the rows of that header
    /// too (review of #40665: a band of the window's colour as high as the header showed beside the top of the chat).
    /// Returns each point inside a pane that did not show what it must.
    ///
    /// `sharesTabRow`: the pane shows its tab strip and the chat's tools are in that row, so the chat's area starts at
    /// the pane's top too, UNDER the row. The chat does not paint the row (its ground stays out of it, Leo 2026-11-03:
    /// no backing behind the tabs), so beside the row the old pane shows no chat ground either; below the row it does.
    private func holesInASplitAcross(newPaneOnTheLeft: Bool, vertical: PaneVerticalTabs? = nil, sharesTabRow: Bool = false) throws -> [String] {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appending(path: "chat-split-across-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let page = directory.appending(path: "index.html")
        try Data("<html><body></body></html>".utf8).write(to: page)

        let size = CGSize(width: 800, height: 600)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.closeAfterTest() }
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        root.wantsLayer = true
        root.layer?.backgroundColor = Self.window.cgColor
        let screen = Screen(frame: root.bounds)
        root.addSubview(screen)
        window.contentView = root
        window.orderFrontRegardless()
        let ground = Self.rgb(Self.chatGround)

        // The pane that shows a chat, at rest in the whole screen, its strip hidden.
        let old = try chatPane(page: page, bar: .top, vertical: vertical, hidesStrip: vertical == nil && !sharesTabRow)
        defer { old.chat.close() }
        let oldHost = PaneHostView(pane: "old", content: old.content, holdsContentInMotion: { true })
        oldHost.frame = CGRect(origin: .zero, size: size)
        screen.addSubview(oldHost)
        old.content.show(old.chat)
        old.chat.applyTheme(force: true)
        root.layoutSubtreeIfNeeded()
        if sharesTabRow {
            // The page reports its tools' width, as its header does once it drew: the pane gives them the row.
            old.chat.model.tabRow.report(width: 120)
            old.content.needsLayout = true
            root.layoutSubtreeIfNeeded()
            try #require(old.chat.tabRowCoverHeight > 8, "fixture: the chat's tools are not in the tab row (the row covers \(old.chat.tabRowCoverHeight) pt of the chat)")
        }
        try #require(old.chat.superview === old.content.contentHost && !old.chat.isHiddenOrHasHiddenAncestor, "fixture: the pane does not show its chat")
        // The header the pane reports with no strip (for its ring), and the rows the chat's area starts at: its top.
        let header = oldHost.headerHeight
        let list = old.content.contentHost.frame.minX
        try #require(header > 8 && header < 100 && oldHost.footerHeight == 0 && old.content.contentHost.frame.minY == 0,
                     "fixture: a chat with no strip reports a header \(header) pt high, a footer \(oldHost.footerHeight) pt high, and its area starts \(old.content.contentHost.frame.minY) pt from the top")
        try #require(vertical == nil ? list == 0 : list > 0 && list < 150, "fixture: the vertical tab list takes \(list) pt")
        // At rest the chat paints the header's rows (x: clear of a vertical list, and away from the centre's loading mark).
        for point in (sharesTabRow ? [] : [CGPoint(x: list + 60, y: header / 2), CGPoint(x: 700, y: header / 2)]) + [CGPoint(x: 700, y: 450)] {
            let atRest = try Self.pixel(of: root, at: point)
            try #require(atRest == ground, "fixture: the chat pane at rest shows \(atRest) at (\(Int(point.x)), \(Int(point.y))), not its own ground \(ground)")
        }

        // The rests, 1 pt apart: the new pane (a chat too) takes one half, the old pane keeps the other.
        let oldRest = newPaneOnTheLeft ? CGRect(x: 401, y: 0, width: 399, height: size.height) : CGRect(x: 0, y: 0, width: 399, height: size.height)
        let newRest = newPaneOnTheLeft ? CGRect(x: 0, y: 0, width: 400, height: size.height) : CGRect(x: 400, y: 0, width: 400, height: size.height)

        let new = try chatPane(page: page, bar: .top, vertical: vertical, hidesStrip: vertical == nil && !sharesTabRow)
        defer { new.chat.close() }
        let newHost = PaneHostView(pane: "new", content: new.content, holdsContentInMotion: { true })
        newHost.frame = CGRect(x: newPaneOnTheLeft ? 0 : size.width, y: 0, width: 0, height: size.height)
        screen.addSubview(newHost)
        new.content.show(new.chat)
        new.chat.applyTheme(force: true)
        try #require(new.chat.superview === new.content.contentHost, "fixture: the new pane does not show its chat")

        // The spring's first frame: each pane hears the rest it heads for and the flag, in the key's turn.
        for (host, rest) in [(oldHost, oldRest), (newHost, newRest)] {
            host.restSize = rest.size
            host.restOffset = CGVector(dx: rest.minX - host.frame.minX, dy: rest.minY - host.frame.minY)
            host.isOnLayoutSpring = true
            host.announceRest()
        }

        // Each display frame of the spring: how wide the new pane is. The key's frame is the first one.
        var holes: [String] = []
        var bands = 0
        for grown in [0, 40, 120, 200, 300, 370, 400] as [CGFloat] {
            let newFrame = newPaneOnTheLeft ? CGRect(x: 0, y: 0, width: grown, height: size.height)
                : CGRect(x: size.width - grown, y: 0, width: grown, height: size.height)
            let oldFrame = newPaneOnTheLeft ? CGRect(x: grown + 1, y: 0, width: size.width - grown - 1, height: size.height)
                : CGRect(x: 0, y: 0, width: size.width - grown - 1, height: size.height)
            PaneHeldContentLandingTests.present(oldHost, at: oldFrame, rest: oldRest)
            PaneHeldContentLandingTests.present(newHost, at: newFrame, rest: newRest)
            // The old pane's chat, held at its rest width at the pane's edge that does not move: in the header's rows
            // and lower, away from its centre.
            var points = (sharesTabRow ? [450] : [header / 2, 450]).map { CGPoint(x: oldRest.minX + list + 60, y: $0) }
            // Beside a shared tab row: no chat ground.
            var clear: [CGPoint] = []
            // The part of the old pane that its held chat does not cover, between the chat and the new pane: in its
            // middle and at its far edge, in the header's rows, in the middle rows and at the bottom.
            let gap = newPaneOnTheLeft ? (min: oldFrame.minX, max: oldRest.minX) : (min: oldRest.maxX, max: oldFrame.maxX)
            if gap.max - gap.min > 8 {
                bands += 1
                let xs = [(gap.min + gap.max) / 2, newPaneOnTheLeft ? gap.min + 3 : gap.max - 3]
                points += xs.flatMap { x in (sharesTabRow ? [300, size.height - 12] : [header / 2, 300, size.height - 12]).map { CGPoint(x: x.rounded(), y: $0) } }
                if sharesTabRow { clear = xs.map { CGPoint(x: $0.rounded(), y: header / 2) } }
            }
            // The new pane's chat, at its rest width: it rides the screen's edge, so its part at that edge shows first
            // (past its own vertical list on a Split Left), away from its centre.
            if grown >= list + 40 { points.append(CGPoint(x: newPaneOnTheLeft ? list + 20 : size.width - 20, y: 150)) }
            for point in points {
                let shown = try Self.pixel(of: root, at: point)
                let inOld = newPaneOnTheLeft ? point.x > grown : point.x < size.width - grown
                if shown != ground {
                    holes.append("new pane \(Int(grown)) pt wide: (\(Int(point.x)), \(Int(point.y))) in the \(inOld ? "old" : "new") pane shows \(shown), not the chat's ground")
                }
            }
            for point in clear {
                let shown = try Self.pixel(of: root, at: point)
                if shown == ground {
                    holes.append("new pane \(Int(grown)) pt wide: (\(Int(point.x)), \(Int(point.y))) beside the old pane's tab row shows the chat's ground")
                }
            }
        }
        try #require(bands >= 4, "the test no longer reaches the frames in which the old pane is wider than its held chat")
        // The held chat, at its rest width, still has its tools in the row: else its area is under the strip and the case is another.
        try #require(!sharesTabRow || old.chat.tabRowCoverHeight > 8 && old.content.contentHost.frame.minY == 0,
                     "fixture: at its rest width the chat's tools left the tab row (the row covers \(old.chat.tabRowCoverHeight) pt, the area starts at \(old.content.contentHost.frame.minY) pt)")

        // The landing: both panes at rest, the content let go.
        oldHost.isOnLayoutSpring = false
        newHost.isOnLayoutSpring = false
        for point in [CGPoint(x: oldRest.minX + list + 60, y: header / 2), CGPoint(x: oldRest.minX + list + 60, y: 450),
                      CGPoint(x: newRest.minX + list + 60, y: header / 2), CGPoint(x: newRest.minX + list + 60, y: 450)] where !sharesTabRow || point.y > header {
            let shown = try Self.pixel(of: root, at: point)
            if shown != ground { holes.append("at rest after the split: (\(Int(point.x)), \(Int(point.y))) shows \(shown), not the chat's ground") }
        }
        return holes
    }

    @Test(.timeLimit(.minutes(1)))
    func aSplitOfAChatPaneShowsNoWindowColourInEitherPane() throws {
        let holes = try holesInASplitDown(bar: .top)
        #expect(holes.isEmpty, "a split of a chat pane showed, inside a pane, something that is not the chat's ground \(Self.rgb(Self.chatGround)) (the window colour is \(Self.rgb(Self.window))), at \(holes.count) points: \(holes)")
    }

    /// `tabs.barPosition` bottom: the held chat has its strip at its own bottom edge. Below that strip the old pane
    /// shows the chat's ground down to its bottom edge (no band of the window colour there), and the strip's row shows
    /// what it shows at rest (not the chat's ground behind the tabs).
    @Test(.timeLimit(.minutes(1)))
    func aSplitOfAChatPaneWithItsTabsAtTheBottomShowsNoWindowColourInEitherPane() throws {
        let holes = try holesInASplitDown(bar: .bottom)
        #expect(holes.isEmpty, "with the tabs at the bottom, a split of a chat pane showed \(holes.count) wrong points (the chat's ground is \(Self.rgb(Self.chatGround)), the window colour \(Self.rgb(Self.window))): \(holes)")
    }

    /// Vertical tabs: the list is at the held chat's leading edge and is clear. It shows what it shows at rest, in the
    /// chat's rows and below them, never the chat's ground behind it.
    @Test(.timeLimit(.minutes(1)))
    func aSplitOfAChatPaneWithVerticalTabsKeepsItsListClear() throws {
        let holes = try holesInASplitDown(bar: .top, vertical: PaneVerticalTabs(collapsed: true))
        #expect(holes.isEmpty, "with vertical tabs, a split of a chat pane showed \(holes.count) wrong points (the chat's ground is \(Self.rgb(Self.chatGround)), the window colour \(Self.rgb(Self.window))): \(holes)")
    }

    /// A hidden tab bar: Split Right leaves the old pane wider than its held chat. That part shows the chat's ground
    /// from the pane's top edge down, the rows of the header the pane reports for its ring too.
    @Test(.timeLimit(.minutes(1)))
    func aSplitRightOfAChatPaneWithAHiddenTabBarShowsNoWindowColourBesideTheChat() throws {
        let holes = try holesInASplitAcross(newPaneOnTheLeft: false)
        #expect(holes.isEmpty, "with a hidden tab bar, Split Right of a chat pane showed \(holes.count) wrong points (the chat's ground is \(Self.rgb(Self.chatGround)), the window colour \(Self.rgb(Self.window))): \(holes)")
    }

    /// The same for Split Left: the held chat rides the pane's trailing edge and the part it does not cover is before it.
    @Test(.timeLimit(.minutes(1)))
    func aSplitLeftOfAChatPaneWithAHiddenTabBarShowsNoWindowColourBesideTheChat() throws {
        let holes = try holesInASplitAcross(newPaneOnTheLeft: true)
        #expect(holes.isEmpty, "with a hidden tab bar, Split Left of a chat pane showed \(holes.count) wrong points (the chat's ground is \(Self.rgb(Self.chatGround)), the window colour \(Self.rgb(Self.window))): \(holes)")
    }

    /// Vertical tabs hide the strip too: the same band, beside the top of the chat, on a Split Right and a Split Left.
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func aSplitAcrossOfAChatPaneWithVerticalTabsShowsNoWindowColourBesideTheChat(newPaneOnTheLeft: Bool) throws {
        let holes = try holesInASplitAcross(newPaneOnTheLeft: newPaneOnTheLeft, vertical: PaneVerticalTabs(collapsed: true))
        #expect(holes.isEmpty, "with vertical tabs, Split \(newPaneOnTheLeft ? "Left" : "Right") of a chat pane showed \(holes.count) wrong points (the chat's ground is \(Self.rgb(Self.chatGround)), the window colour \(Self.rgb(Self.window))): \(holes)")
    }

    /// A tab strip that shows, with the chat's tools in it (review of #40822): the chat's area starts at the pane's top,
    /// under the row, but the chat does not paint the row. Beside the row the old pane shows no chat ground (no backing
    /// behind or beside the tabs); below the row it shows the chat's ground, on a Split Right and a Split Left.
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func aSplitAcrossOfAChatThatSharesItsTabRowPutsNoGroundBesideTheRow(newPaneOnTheLeft: Bool) throws {
        let holes = try holesInASplitAcross(newPaneOnTheLeft: newPaneOnTheLeft, sharesTabRow: true)
        #expect(holes.isEmpty, "with the chat's tools in the tab row, Split \(newPaneOnTheLeft ? "Left" : "Right") of a chat pane showed \(holes.count) wrong points (the chat's ground is \(Self.rgb(Self.chatGround)), the window colour \(Self.rgb(Self.window))): \(holes)")
    }
}
