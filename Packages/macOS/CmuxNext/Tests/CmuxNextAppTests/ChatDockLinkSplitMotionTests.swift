import AppKit
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
        func makeContentView(for pane: PaneID) -> NSView { NSView() }
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
        let provider = Panes()
        let model: LayoutModel
        let root: LayoutRootView
        let window: NSWindow

        init() {
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
}
