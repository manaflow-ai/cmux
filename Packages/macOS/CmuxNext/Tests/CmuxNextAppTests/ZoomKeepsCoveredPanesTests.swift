import AppKit
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Testing

/// A zoom keeps the panes it covers and the unzoom shows them again as they were (RESIZE VIDEOS Z1, 5 of 5 films: one
/// frame of 42-70 ms when a zoom of 12 panes lands and again when the unzoom starts, with or without load). The zoom's
/// landing released every covered pane (11 pane controllers torn down in one frame) and the unzoom made each one
/// again (11 new pane controllers, toolbars and themes in one frame). Now the landing hides them (a hidden terminal
/// stops drawing) and the unzoom takes the same hosts back; a pane closed while zoomed is torn down at the unzoom.
/// The test is the clock (120 Hz).
@MainActor
@Suite(.closesItsWindows)
struct ZoomKeepsCoveredPanesTests {
    final class Panes: LayoutPaneContentProvider {
        var made: [PaneID] = []
        var released: [PaneID] = []
        func makeContentView(for pane: PaneID) -> NSView {
            made.append(pane)
            return NSView()
        }
        func releaseContentView(_ view: NSView, for pane: PaneID) { released.append(pane) }
    }

    static let four: SplitNode = .split("r", axis: .horizontal, ratio: 0.5,
                                        a: .split("a", axis: .vertical, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2")),
                                        b: .split("b", axis: .vertical, ratio: 0.5, a: .leaf("p3"), b: .leaf("p4")))
    static let threeLeft: SplitNode = .split("r", axis: .horizontal, ratio: 0.5,
                                             a: .split("a", axis: .vertical, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2")),
                                             b: .leaf("p3"))

    final class Screen {
        let provider = Panes()
        let model: LayoutModel
        let root: LayoutRootView
        let window: NSWindow

        init() {
            model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(ZoomKeepsCoveredPanesTests.four))],
                                activeScreenID: "s", focusedPane: "p1")
            root = LayoutRootView(model: model, contentProvider: provider)
            root.context.reduceMotionOverride = false
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless], backing: .buffered, defer: true)
            window.contentView = root
            root.layoutSubtreeIfNeeded()
            root.driver.isManual = true
            land()
        }

        var screen: ScreenContentView { root.screenViews["s"]! }

        func show(_ tree: SplitNode, zoomed: Bool) {
            model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(tree), zoomed: zoomed)])
            root.syncWithModel()
        }

        func land() {
            var frames = 0
            while root.advanceFrame(1.0 / 120), frames < 600 { frames += 1 }
        }
    }

    @Test func aZoomKeepsItsCoveredPanesAndTheUnzoomShowsThemAgain() throws {
        let screen = Screen()
        defer { screen.window.closeAfterTest() }
        let covered: [PaneID] = ["p2", "p3", "p4"]
        let hosts = try covered.map { try #require(screen.root.context.hosts[$0]) }
        let made = screen.provider.made.count

        screen.show(.leaf("p1"), zoomed: true)
        screen.land()
        #expect(screen.provider.released.isEmpty, "the zoom's landing tore down the panes it covers: \(screen.provider.released)")
        #expect(hosts.allSatisfy { $0.isHidden && $0.superview === screen.screen }, "the covered panes are kept, hidden")

        screen.show(Self.four, zoomed: false)
        #expect(screen.provider.made.count == made, "the unzoom made panes again: \(screen.provider.made.dropFirst(made))")
        for (pane, host) in zip(covered, hosts) {
            #expect(screen.root.context.hosts[pane] === host, "\(pane.rawValue) came back with a new host")
            #expect(!host.isHidden, "\(pane.rawValue) shows again")
        }
        screen.land()
        #expect(screen.provider.released.isEmpty, "the unzoom released a pane that came back: \(screen.provider.released)")
    }

    @Test func aPaneClosedWhileZoomedIsTornDownAtTheUnzoom() throws {
        let screen = Screen()
        defer { screen.window.closeAfterTest() }
        let closed = try #require(screen.root.context.hosts["p4"])
        screen.show(.leaf("p1"), zoomed: true)
        screen.land()
        screen.show(Self.threeLeft, zoomed: false)
        screen.land()
        #expect(screen.provider.released == ["p4"], "only the pane that did not come back goes: \(screen.provider.released)")
        #expect(closed.superview == nil)
    }
}
