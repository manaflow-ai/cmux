import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextLayout
import Foundation
import Testing

/// Canvas overview, reveal and arrange actions (INVENTORY row 31, plans/cmux-next/canvas-layout.md),
/// run through the registry on a canvas screen of two panes.
@MainActor @Suite(.serialized)
struct CanvasArrangeActionTests {
    static let ids: [ActionID] = [
        "canvasOverview", "canvasTidy", "canvasRevealFocusedPane", "canvasAlignLeft", "canvasAlignRight", "canvasAlignTop",
        "canvasAlignBottom", "canvasEqualizeWidths", "canvasEqualizeHeights", "canvasDistributeHorizontally",
        "canvasDistributeVertically",
    ]

    @Test func everyCanvasActionIsAvailable() {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        for id in Self.ids {
            #expect(services.registry.unavailableReason(for: id) == nil, "\(id) is still greyed out")
        }
    }

    /// A canvas whose two panes sit at `first` and `second`.
    private static func canvas(_ first: CGRect, _ second: CGRect) async throws
        -> (AppServices, WindowController, WorkspaceContentController, [PaneController], CmuxNextLayout.ScreenID) {
        let (services, controller, content) = try await CanvasLayoutActionTests.window()
        let panes = content.panes.values.sorted { $0.paneKey < $1.paneKey }
        try #require(CanvasLayoutActionTests.run("toggleCanvasLayout", on: panes[0], services) == nil)
        let model = content.layoutModel
        let screen = try #require(model.activeScreenID)
        model.setCanvasFrame(first, for: panes[0].layoutPaneID)
        model.setCanvasFrame(second, for: panes[1].layoutPaneID)
        return (services, controller, content, panes, screen)
    }

    private static func frames(_ content: WorkspaceContentController, _ panes: [PaneController], _ screen: CmuxNextLayout.ScreenID) throws -> [CGRect] {
        let canvas = try #require(content.layoutModel.canvas(for: screen))
        return try panes.map { try #require(canvas.frames[$0.layoutPaneID]) }
    }

    @Test func tidyPacksPanesIntoARowAtTheGap() async throws {
        let (services, controller, content, panes, screen) = try await Self.canvas(CGRect(x: 40, y: 60, width: 400, height: 300),
                                                                                  CGRect(x: 900, y: 120, width: 300, height: 200))
        defer { controller.teardown(); controller.window?.close() }
        #expect(CanvasLayoutActionTests.run("canvasTidy", on: panes[0], services) == nil)
        #expect(try Self.frames(content, panes, screen) == [CGRect(x: 40, y: 60, width: 400, height: 300),
                                                            CGRect(x: 456, y: 60, width: 300, height: 200)])
    }

    @Test func alignEqualizeAndDistributeMoveEveryPane() async throws {
        let (services, controller, content, panes, screen) = try await Self.canvas(CGRect(x: 40, y: 60, width: 400, height: 300),
                                                                                  CGRect(x: 900, y: 120, width: 300, height: 200))
        defer { controller.teardown(); controller.window?.close() }
        func run(_ id: ActionID) { #expect(CanvasLayoutActionTests.run(id, on: panes[0], services) == nil, "\(id) refused") }
        run("canvasAlignTop")
        #expect(try Self.frames(content, panes, screen).map(\.minY) == [60, 60])
        run("canvasAlignBottom")
        #expect(try Self.frames(content, panes, screen).map(\.maxY) == [360, 360])
        run("canvasAlignRight")
        #expect(try Self.frames(content, panes, screen).map(\.maxX) == [1200, 1200])
        run("canvasAlignLeft")
        #expect(try Self.frames(content, panes, screen).map(\.minX) == [800, 800])
        // The targeted pane is the reference the equalize commands copy.
        run("canvasEqualizeWidths")
        #expect(try Self.frames(content, panes, screen).map(\.width) == [400, 400])
        run("canvasEqualizeHeights")
        #expect(try Self.frames(content, panes, screen).map(\.height) == [300, 300])
        run("canvasDistributeVertically")
        let stacked = try Self.frames(content, panes, screen).sorted { $0.minY < $1.minY }
        #expect(stacked[1].minY == stacked[0].maxY + 16)
        run("canvasDistributeHorizontally")
        let row = try Self.frames(content, panes, screen).sorted { $0.minX < $1.minX }
        #expect(row[1].minX == row[0].maxX + 16)
    }

    @Test func overviewShowsEveryPaneAndReturnsAndRevealPansToThePane() async throws {
        let (services, controller, content, panes, screen) = try await Self.canvas(CGRect(x: 0, y: 0, width: 400, height: 300),
                                                                                  CGRect(x: 6000, y: 3000, width: 400, height: 300))
        defer { controller.teardown(); controller.window?.close() }
        let model = content.layoutModel
        let viewport = content.layoutView.bounds.size
        let before = try #require(model.canvas(for: screen)?.camera)
        #expect(CanvasLayoutActionTests.run("canvasOverview", on: panes[0], services) == nil)
        let overview = try #require(model.canvas(for: screen)?.camera)
        let shown = overview.visibleRect(viewport: viewport)
        #expect(shown.contains(CGRect(x: 0, y: 0, width: 6400, height: 3300)), "the overview leaves a pane out: \(shown)")
        #expect(overview.zoom < 1)
        #expect(CanvasLayoutActionTests.run("canvasOverview", on: panes[0], services) == nil)
        #expect(model.canvas(for: screen)?.camera == before, "a second overview did not return")

        // The far pane is off screen; revealing it pans until it shows whole.
        #expect(CanvasLayoutActionTests.run("canvasRevealFocusedPane", on: panes[1], services) == nil)
        let revealed = try #require(model.canvas(for: screen)?.camera).visibleRect(viewport: viewport)
        #expect(revealed.contains(CGRect(x: 6000, y: 3000, width: 400, height: 300)), "\(revealed) does not show the pane")
    }
}
