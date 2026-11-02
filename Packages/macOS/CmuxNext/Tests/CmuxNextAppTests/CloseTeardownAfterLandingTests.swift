import AppKit
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Testing

/// A close that springs tears the closed pane down when its motion lands, not in its first frame (RESIZE VIDEOS F1,
/// STATUS 4500 and 4541: the close's first 3 frames missed 1-3 refreshes at 120 Hz, 8-21 ms of main thread each,
/// 39% of it the Core Animation commit that also took the closed host's layers out of the tree). In the close's own
/// turn the closed host is hidden (no hit, no focus, no ring), its content is not released and its layers stay in the
/// tree; the frame the motion lands in releases it, once. A close taken back before that shows the same host again.
/// The test is the clock (120 Hz).
@MainActor
@Suite(.closesItsWindows)
struct CloseTeardownAfterLandingTests {
    final class Panes: LayoutPaneContentProvider {
        var released: [PaneID] = []
        func makeContentView(for pane: PaneID) -> NSView { NSView() }
        func releaseContentView(_ view: NSView, for pane: PaneID) { released.append(pane) }
    }

    final class Strip {
        let provider = Panes()
        let model: LayoutModel
        let root: LayoutRootView
        let window: NSWindow

        init(reduceMotion: Bool = false) {
            model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: CloseTeardownAfterLandingTests.columns(["p1", "p2", "p3"]))],
                                activeScreenID: "s", focusedPane: "p2")
            root = LayoutRootView(model: model, contentProvider: provider)
            root.context.reduceMotionOverride = reduceMotion
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: true)
            window.contentView = root
            root.layoutSubtreeIfNeeded()
            root.driver.isManual = true
            for _ in 0..<600 where root.advanceFrame(1.0 / 120) {}
        }

        var screen: ScreenContentView { root.screenViews["s"]! }

        func show(_ panes: [PaneID], focus: PaneID) {
            model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: CloseTeardownAfterLandingTests.columns(panes))])
            root.syncWithModel()
            model.focus(focus, notify: false)
            root.syncWithModel()
        }
    }

    static func columns(_ panes: [PaneID]) -> ScreenLayout {
        .columns(panes.map { LayoutColumn(id: ColumnID("c-\($0.rawValue)"), width: 1.0 / 3, root: .leaf($0)) })
    }

    @Test func aSpringingCloseTearsTheClosedPaneDownWhenItLands() throws {
        let strip = Strip()
        defer { strip.window.closeAfterTest() }
        let closed = try #require(strip.root.context.hosts["p2"])
        #expect(closed.superview === strip.screen && !closed.isHidden)

        strip.show(["p1", "p3"], focus: "p1")
        #expect(strip.screen.hasMotion, "the neighbours spring into the closed column's place")
        #expect(strip.root.context.hosts["p2"] == nil, "the closed pane has left the layout")
        #expect(strip.provider.released.isEmpty, "the close's own turn released the closed content: \(strip.provider.released)")
        #expect(closed.superview === strip.screen, "the close's own turn took the closed host's layers out of the tree")
        #expect(closed.isHidden && closed.chrome.isHidden, "the closed host and its ring are hidden from the close's first frame")

        var frames = 0
        while strip.root.advanceFrame(1.0 / 120), frames < 600 {
            frames += 1
            if strip.screen.hasMotion {
                #expect(strip.provider.released.isEmpty, "frame \(frames) released the closed content before the motion landed")
            }
        }
        #expect(frames > 10, "the close springs over several frames (\(frames))")
        #expect(strip.provider.released == ["p2"], "the landing releases the closed content once: \(strip.provider.released)")
        #expect(closed.superview == nil && closed.chrome.superview == nil, "the landing takes the closed host and its ring out of the tree")
    }

    @Test func aCloseTakenBackBeforeItLandsShowsTheSameHostAgain() throws {
        let strip = Strip()
        defer { strip.window.closeAfterTest() }
        let closed = try #require(strip.root.context.hosts["p2"])
        strip.show(["p1", "p3"], focus: "p1")
        for _ in 0..<3 { strip.root.advanceFrame(1.0 / 120) }
        #expect(strip.screen.hasMotion)

        strip.show(["p1", "p2", "p3"], focus: "p2")
        #expect(strip.root.context.hosts["p2"] === closed, "the pane that came back has its own host again")
        #expect(!closed.isHidden && closed.superview === strip.screen)
        for _ in 0..<600 where strip.root.advanceFrame(1.0 / 120) {}
        #expect(strip.provider.released.isEmpty, "the pane that came back was released: \(strip.provider.released)")
        #expect(!closed.isHidden && !closed.chrome.isHidden, "it shows, with its ring, after the motion")
    }

    /// Guard: with no motion the close tears the pane down in its own turn, as before.
    @Test func aCloseWithoutMotionTearsTheClosedPaneDownAtOnce() throws {
        let strip = Strip(reduceMotion: true)
        defer { strip.window.closeAfterTest() }
        let closed = try #require(strip.root.context.hosts["p2"])
        strip.show(["p1", "p3"], focus: "p1")
        #expect(strip.provider.released == ["p2"])
        #expect(closed.superview == nil)
    }
}
