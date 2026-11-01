import AppKit
@testable import CmuxNextLayout
import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// A strip divider partly scrolled under a docked column showed its resize cursor over the docked
/// pane (Leo 2026-10-21: hovering a block header in the agent chat's transcript showed a resize
/// cursor). AppKit cursor rects ignore the siblings above a view: the dock's pane did not hide the
/// strip handle's rect under it. The handle's cursor rect, and the mouse area a page's click catcher
/// covers, now stop where the dock begins.
@MainActor
@Suite(.closesItsWindows)
struct DividerCursorUnderDockTests {
    final class Panes: LayoutPaneContentProvider {
        func makeContentView(for pane: PaneID) -> NSView { NSView() }
    }

    final class Fixture {
        let provider = Panes()
        let model: LayoutModel
        let root: LayoutRootView
        let window: NSWindow

        /// Two 60% strip columns, the second split top and bottom, and a right dock: the second
        /// column runs on under the dock, and so does its split's divider.
        init(mode: DockMode) {
            let layout = ScreenLayout.columns([
                LayoutColumn(id: "c1", width: 0.6, root: .leaf("p1")),
                LayoutColumn(id: "c2", width: 0.6,
                             root: .split("x", axis: .vertical, ratio: 0.5, a: .leaf("p2"), b: .leaf("p3"))),
                LayoutColumn(id: "dock", width: 0.3, root: .leaf("chat"), dock: DockColumn(edge: .right, mode: mode)),
            ])
            model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: layout)], activeScreenID: "s", focusedPane: "p1")
            // A pinned style with divider lines (`borders`): the live one follows the process-wide
            // DesignSettings, which a settings test leaves at the app's defaults (flat-sidebar-line, whose
            // `none` separation draws no hover line) when it runs earlier in the same process.
            model.followsDesignMetrics = false
            root = LayoutRootView(model: model, contentProvider: provider)
            root.context.reduceMotionOverride = true
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: true)
            window.contentView = root
            root.layoutSubtreeIfNeeded()
            root.driver.isManual = true
            for _ in 0..<600 where root.advanceFrame(1.0 / 120) {}
        }

        var screen: ScreenContentView { root.screenViews["s"]! }
    }

    @Test(arguments: [DockMode.docked, DockMode.overlay])
    func aStripDividerUnderADockKeepsItsCursorOutOfTheDock(_ mode: DockMode) throws {
        let fixture = Fixture(mode: mode)
        defer { fixture.window.closeAfterTest() }
        let screen = fixture.screen
        let cover = try #require(screen.geometry.dock.first { $0.column == "dock" }).cover
        let handle = try #require(screen.dividerViews[.split("x")])
        try #require(!handle.isHidden, "the divider shows beside the dock")
        try #require(handle.frame.intersection(cover).width > 1, "the divider runs on under the dock: \(handle.frame), dock \(cover)")

        let cursor = screen.convert(handle.cursorRectInBounds, from: handle)
        #expect(!cursor.isEmpty, "the divider keeps its cursor where it shows: \(cursor)")
        let under = cursor.intersection(cover)
        #expect(under.isNull || under.width < 0.5 || under.height < 0.5,
                "no resize cursor over the docked pane: cursor \(cursor), dock \(cover)")

        let area = try #require(screen.dividerMouseAreas.first { $0.id == DividerHandleView.Kind.split("x").mouseAreaID })
        let areaUnder = area.rect.intersection(cover)
        #expect(areaUnder.isNull || areaUnder.width < 0.5 || areaUnder.height < 0.5,
                "a page's click catcher stops at the dock too: \(area.rect), dock \(cover)")
    }

    /// Hover follows the same clip: the pointer over the docked part of the divider leaves it
    /// unhovered, and once hovered beside the dock its drawn line (a hole in a page) stops there too.
    @Test(arguments: [DockMode.docked, DockMode.overlay])
    func aStripDividerUnderADockIsNotHoveredOrDrawnThere(_ mode: DockMode) throws {
        let fixture = Fixture(mode: mode)
        defer { fixture.window.closeAfterTest() }
        let screen = fixture.screen
        let cover = try #require(screen.geometry.dock.first { $0.column == "dock" }).cover
        let handle = try #require(screen.dividerViews[.split("x")])
        let under = handle.frame.intersection(cover)
        try #require(under.width > 1, "the divider runs on under the dock: \(handle.frame), dock \(cover)")
        // Where it shows its resize cursor (an overlay dock's uncovered area stops short of its cover).
        let beside = screen.convert(handle.cursorRectInBounds, from: handle)
        try #require(beside.width > 1 && beside.height > 1, "the divider shows beside the dock: \(beside), dock \(cover)")
        var pointer = CGPoint(x: under.midX, y: under.midY)
        fixture.root.context.hoverPointer = { _ in screen.convert(pointer, to: nil) }
        fixture.root.context.hoverReachesWindow = { _ in true }

        screen.refreshDividerHover()
        #expect(!handle.isHovered, "the pointer over the docked pane hovers no divider under it")

        pointer = CGPoint(x: beside.midX, y: beside.midY)
        screen.refreshDividerHover()
        #expect(handle.isHovered, "beside the dock the divider still hovers")
        let lines = screen.dividerLineRects.filter { $0.intersects(handle.frame) }
        try #require(!lines.isEmpty, "the hovered divider draws its line")
        for line in lines {
            let drawnUnder = line.intersection(cover)
            #expect(drawnUnder.isNull || drawnUnder.width < 0.5 || drawnUnder.height < 0.5,
                    "the hovered line stops at the dock: line \(line), dock \(cover)")
        }
    }
}
