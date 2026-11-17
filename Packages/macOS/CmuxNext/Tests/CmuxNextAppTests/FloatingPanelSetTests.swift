import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Testing

/// The panels of a layout root's floating panes (`FloatingPanelSet`): each floating pane that shows is one panel,
/// a child window of the root's window, with the pane's own host view in it.
///
/// The window of each test is never on a display, and the test is the end of each frame (`Fixture.endFrame`). What
/// a real screen shows (the order of the panels above the window, the frame in which a panel comes) is not read
/// here: the tests read the child windows of the window, their frames and the views in them.
@MainActor @Suite(.serialized, .closesItsWindows) struct FloatingPanelSetTests {
    @MainActor final class Panes: LayoutPaneContentProvider {
        var made: [PaneID] = []
        var released: [PaneID] = []
        func makeContentView(for pane: PaneID) -> NSView {
            made.append(pane)
            return NSView()
        }

        func releaseContentView(_ view: NSView, for pane: PaneID) { released.append(pane) }
    }

    /// One screen with the tiled pane `p1` and a list of floating panes, in a window that is not on a display.
    @MainActor final class Fixture {
        let provider = Panes()
        let model: LayoutModel
        let root: LayoutRootView
        let window: NSWindow
        /// The work that the set left for the end of a frame.
        var later: [@MainActor () -> Void] = []
        var intents: [LayoutIntent] = []
        /// Each panel that the set had, to close it at the test's end.
        var seen: [PanePanel] = []

        init(floating: [LayoutFloatingPane]) {
            model = LayoutModel(screens: [Self.screen(floating)], activeScreenID: "s", focusedPane: "p1")
            root = LayoutRootView(model: model, contentProvider: provider)
            window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1200, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            model.intentHandler = { [unowned self] in self.intents.append($0) }
            root.context.floatingPanels.afterFrame = { [unowned self] in self.later.append($0) }
            window.contentView = root
            root.layoutSubtreeIfNeeded()
        }

        static func screen(_ floating: [LayoutFloatingPane]) -> LayoutScreen {
            LayoutScreen(id: "s", name: "s", layout: .splits(.leaf("p1")), floating: floating)
        }

        var set: FloatingPanelSet { root.context.floatingPanels }

        /// The panes of the panels that are children of the window, in the order of the window's list.
        var shown: [String] { (window.childWindows ?? []).compactMap { ($0 as? PanePanel)?.pane } }

        /// The end of a frame: the work that waited for it runs.
        func endFrame() {
            let work = later
            later = []
            for item in work { item() }
            seen += set.panels.values.filter { panel in !seen.contains { $0 === panel } }
        }

        /// The daemon's next list for the screen, and the end of the frame that shows it.
        func show(_ floating: [LayoutFloatingPane]) {
            model.apply(screens: [Self.screen(floating)])
            root.syncWithModel()
            root.layoutSubtreeIfNeeded()
            endFrame()
        }

        func close() {
            for panel in seen {
                panel.parent?.removeChildWindow(panel)
                panel.closeAfterTest()
            }
            window.closeAfterTest()
        }
    }

    static let middle = LayoutFloatingPane(pane: "f1", frame: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
    static let corner = LayoutFloatingPane(pane: "f2", frame: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3))

    @Test func aFloatingPaneShowsInOnePanelOfTheWindowWithItsOwnHost() throws {
        let fixture = Fixture(floating: [Self.middle])
        defer { fixture.close() }
        #expect(fixture.set.panels.isEmpty, "a window changed inside the layout pass that found the floating pane")
        fixture.endFrame()
        let panel = try #require(fixture.set.panels["f1"])
        #expect(panel.parent === fixture.window, "the panel is not a child of the window that shows its screen")
        #expect(fixture.shown == ["f1"])
        #expect(fixture.set.made == 1)
        let host = fixture.root.context.host(for: "f1")
        #expect(host.window === panel, "the pane's host is not in its panel")
        #expect(host.frame.minY == FloatingPanelFrame.barHeight, "the pane's host is not under the bar")
        #expect(fixture.provider.made.filter { $0 == "f1" }.count == 1, "the pane's content was made more than one time")
        #expect(fixture.root.context.host(for: "p1").window === fixture.window, "the tiled pane left the window")
        let planned = try #require(fixture.set.plan.panels.first)
        #expect(fixture.set.area.width > 0 && fixture.set.area.height > 0)
        #expect(planned.frame.width > 0 && planned.frame.height > 0)
        #expect(panel.frame == planned.frame, "the panel is not at the frame of the plan")
    }

    @Test func aScreenWithNoFloatingPaneMakesNoPanelAndAsksForNoFrame() {
        let fixture = Fixture(floating: [])
        defer { fixture.close() }
        #expect(fixture.later.isEmpty, "a screen with no floating pane left work for the end of a frame")
        #expect(fixture.set.made == 0 && fixture.shown.isEmpty)
    }

    /// The order that this test reads is the order of the window's child list, not the order on a display.
    @Test func thePanelsAreInTheOrderOfTheListAndANewOrderMakesNoPanelAgain() {
        let fixture = Fixture(floating: [Self.middle, Self.corner])
        defer { fixture.close() }
        fixture.endFrame()
        #expect(fixture.shown == ["f1", "f2"])
        fixture.show([Self.corner, Self.middle])
        #expect(fixture.shown == ["f2", "f1"], "the window's panels are not in the order of the daemon's list")
        #expect(fixture.set.made == 2, "a new order made a panel again")
        #expect(fixture.provider.made.filter { $0 != "p1" }.count == 2, "a new order made a pane's content again")
    }

    @Test func aPanelThatLeavesKeepsItsViewsAndComesBackAsTheSamePanel() throws {
        let fixture = Fixture(floating: [Self.middle])
        defer { fixture.close() }
        fixture.endFrame()
        let panel = try #require(fixture.set.panels["f1"])
        let host = fixture.root.context.host(for: "f1")
        // The root stops showing (its workspace is parked or hidden): the panel goes at once, before any frame.
        fixture.root.isHidden = true
        #expect(panel.parent == nil && fixture.shown.isEmpty, "a panel stayed over a window that does not show its workspace")
        #expect(fixture.set.panels["f1"] === panel, "a panel that left the display ended")
        #expect(host.window === panel, "the pane's host left its panel when the panel left the display")
        #expect(fixture.provider.released.isEmpty, "a pane's content ended when its panel left the display")
        // It shows again: the content's frame first, then the panel.
        fixture.root.isHidden = false
        #expect(fixture.shown.isEmpty, "a panel came in the same frame as the content of its workspace")
        fixture.endFrame()
        #expect(fixture.shown == ["f1"] && fixture.set.panels["f1"] === panel, "the pane did not come back in its own panel")
        #expect(fixture.set.made == 1, "a panel was made again")
        #expect(fixture.provider.made.filter { $0 == "f1" }.count == 1, "the pane's content was made again")
        #expect(host.window === panel)
    }

    @Test func aPaneThatClosesLosesItsPanelAndItsContentIsReleasedOneTime() throws {
        let fixture = Fixture(floating: [Self.middle])
        defer { fixture.close() }
        fixture.endFrame()
        let panel = try #require(fixture.set.panels["f1"])
        fixture.show([])
        #expect(fixture.set.panels.isEmpty && fixture.shown.isEmpty, "the panel of a pane that closed stayed")
        #expect(panel.parent == nil)
        #expect(fixture.provider.released == ["f1"], "the content of the pane that closed: released \(fixture.provider.released)")
    }

    @Test func aMoveWritesOneFrameToTheModelAtItsRelease() throws {
        let fixture = Fixture(floating: [Self.middle])
        defer { fixture.close() }
        fixture.endFrame()
        let panel = try #require(fixture.set.panels["f1"])
        let area = fixture.set.area
        fixture.intents = []
        panel.setFrameOrigin(NSPoint(x: panel.frame.minX + area.width * 0.125, y: panel.frame.minY))
        #expect(fixture.intents.isEmpty, "a move wrote a frame before its release")
        panel.onMoved?()
        let frames = fixture.intents.compactMap { intent -> CGRect? in
            if case let .setFloatingFrame(pane, frame) = intent, pane == "f1" { return frame }
            return nil
        }
        #expect(frames.count == 1, "the release of a move wrote \(frames.count) frames")
        let frame = try #require(frames.first)
        #expect(abs(frame.minX - 0.375) < 0.01 && abs(frame.minY - 0.25) < 0.01, "the frame of the release: \(frame)")
        #expect(abs(frame.width - 0.5) < 0.01 && abs(frame.height - 0.5) < 0.01, "a move changed the size: \(frame)")
        let planned = try #require(fixture.set.plan.panels.first)
        #expect(panel.frame == planned.frame, "after the release the panel is not at the frame of the model's answer")
    }
}
