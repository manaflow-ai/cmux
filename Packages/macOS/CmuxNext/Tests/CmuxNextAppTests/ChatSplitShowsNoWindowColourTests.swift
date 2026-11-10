import AppKit
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextLayout
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

    /// One pane's content as the app builds it (its tab strip over its content area) showing a chat whose own ground
    /// is ``chatGround``. The page has not drawn: the chat shows its ground, as a pane does until its page's frame.
    private func chatPane(page: URL) throws -> (content: PaneContentView, chat: AgentPaneView) {
        let reveal = LaunchReveal()
        reveal.markAllReady()
        let content = PaneContentView(stripModel: TabStripModel(tabs: [TabItem(id: TabID("chat"), title: "chat")]), reveal: reveal)
        content.paneScope.setSurfaceBackgrounds(SurfaceBackgrounds(overrides: [.agentPane: SurfaceBackground(color: Self.chatGround, opacity: 1)]))
        let chat = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost()), source: .bundled(page)))
        return (content, chat)
    }

    /// The points of a pane's rect that its content area covers in a frame, away from the centre (a loading mark may
    /// draw there): `ys` are distances from the screen's top.
    private static func points(width: CGFloat, ys: [CGFloat]) -> [CGPoint] {
        ys.flatMap { y in [0.25, 0.75].map { CGPoint(x: (width * $0).rounded(), y: y.rounded()) } }
    }

    @Test(.timeLimit(.minutes(1)))
    func aSplitOfAChatPaneShowsNoWindowColourInEitherPane() throws {
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

        // The pane that shows a chat, at rest in the whole screen.
        let old = try chatPane(page: page)
        let oldHost = PaneHostView(pane: "old", content: old.content, holdsContentInMotion: { true })
        oldHost.frame = CGRect(origin: .zero, size: size)
        screen.addSubview(oldHost)
        old.content.show(old.chat)
        old.chat.applyTheme(force: true)
        root.layoutSubtreeIfNeeded()
        try #require(old.chat.superview === old.content.contentHost && !old.chat.isHiddenOrHasHiddenAncestor, "fixture: the pane does not show its chat")
        let header = oldHost.headerHeight
        try #require(header < 100, "fixture: the pane's header is \(header) pt high")
        let atRest = try Self.pixel(of: root, at: CGPoint(x: 200, y: header + 150))
        try #require(atRest == Self.rgb(Self.chatGround), "fixture: the chat pane at rest shows \(atRest), not its own ground \(Self.rgb(Self.chatGround))")

        // Split Down: the old pane rests in the top half, the new pane (a chat too) in the bottom half, 1 pt apart.
        let oldRest = CGRect(x: 0, y: 0, width: size.width, height: 299)
        let newRest = CGRect(x: 0, y: 300, width: size.width, height: 300)
        let new = try chatPane(page: page)
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
            // The old pane under its header: in its chat, in the middle of what the chat does not cover, at its bottom edge.
            var ys: [CGFloat] = [header + 150, oldRest.height - 12]
            if oldFrame.height > oldRest.height + 8 {
                bands += 1
                ys += [(oldRest.height + oldFrame.height) / 2, oldFrame.maxY - 4]
            }
            // The new pane under its header (its content rides its top edge, so its strip shows from its first frames).
            if newFrame.height >= header + 170 { ys += [newFrame.minY + header + 150, newFrame.maxY - 8] }
            for point in Self.points(width: size.width, ys: ys) {
                let shown = try Self.pixel(of: root, at: point)
                if shown == Self.rgb(Self.window) {
                    holes.append("divider \(Int(divider)): (\(Int(point.x)), \(Int(point.y))) in the \(point.y < divider ? "old" : "new") pane")
                }
            }
        }
        try #require(bands >= 4, "the test no longer reaches the frames in which the old pane is taller than its held chat")
        #expect(holes.isEmpty, "the window colour \(Self.rgb(Self.window)) showed inside a pane during the split, at \(holes.count) points: \(holes)")

        // The landing: both panes at rest, the content let go.
        oldHost.isOnLayoutSpring = false
        newHost.isOnLayoutSpring = false
        for y in [header + 150, oldRest.height - 12, newRest.minY + header + 150, newRest.maxY - 8] as [CGFloat] {
            let shown = try Self.pixel(of: root, at: CGPoint(x: 200, y: y))
            #expect(shown != Self.rgb(Self.window), "at rest after the split, (200, \(Int(y))) shows the window colour \(shown)")
        }
    }
}
