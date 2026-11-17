import CmuxNextBridge
@testable import CmuxNextDaemon
import CmuxNextLayout
import CoreGraphics
import Testing

/// The frame of a floating pane is four fractions of the screen's pane area, and its corner can be outside that
/// area: a floating pane can be beside its window. The app holds a frame to the daemon's limits (a corner not
/// farther than 16 times the pane area from its corner, a size from 0.15 to 8 times the pane area) and does not
/// move it into the pane area: not when a person lets go of a move, and not when the daemon's list comes.
@MainActor struct FloatingFrameLimitsTests {
    /// One screen with the tiled pane `p1` and the floating pane `f1`, and each intent that the model sends.
    @MainActor final class Fixture {
        let model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(.leaf("p1")),
                                                       floating: [LayoutFloatingPane(pane: "f1", frame: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))])],
                                activeScreenID: "s", focusedPane: "p1")
        var sent: [CGRect] = []

        init() {
            model.intentHandler = { [weak self] intent in
                if case let .setFloatingFrame(_, frame) = intent { self?.sent.append(frame) }
            }
        }

        var frame: CGRect? { model.screens.first?.floating.first?.frame }
    }

    @Test func aFrameWhoseCornerIsOutsideThePaneAreaStaysWhereThePersonLeftIt() {
        let fixture = Fixture()
        let beside = CGRect(x: -0.5, y: 1.25, width: 0.5, height: 0.5)
        #expect(fixture.model.setFloatingFrame("f1", frame: beside))
        #expect(fixture.frame == beside, "the app moved the frame into the pane area: \(String(describing: fixture.frame))")
        #expect(fixture.sent == [beside], "the frame that goes to the daemon: \(fixture.sent)")
    }

    @Test func aFrameIsHeldToTheLimitsOfTheDaemon() {
        let fixture = Fixture()
        #expect(fixture.model.setFloatingFrame("f1", frame: CGRect(x: -20, y: 20, width: 9, height: 0.01)))
        #expect(fixture.frame == CGRect(x: -16, y: 16, width: 8, height: 0.15), "the limits: \(String(describing: fixture.frame))")
        #expect(fixture.sent == [CGRect(x: -16, y: 16, width: 8, height: 0.15)], "the frame that goes to the daemon: \(fixture.sent)")
    }

    @Test func aFrameOfTheDaemonsListKeepsItsCornerOutsideThePaneArea() throws {
        let store = DaemonStore()
        // The daemon's tiled layout has no floating pane: pane 1 is tiled, pane 2 floats.
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), columns: [ColumnSnapshot(id: 1, width: 1, layout: .leaf(1))],
                                    panes: [PaneSnapshot(id: 1, tabs: [TabSnapshot(surface: 101)]),
                                            PaneSnapshot(id: 2, tabs: [TabSnapshot(surface: 102)])],
                                    floating: [FloatingPaneSnapshot(pane: 2, frame: .init(x: -0.5, y: 1.25, w: 0.5, h: 0.5))])
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w", screens: [screen])]))
        let workspace = try #require(store.workspaces.first)
        let mapped = try #require(LayoutMapping.shared.map(workspace).screens.first)
        #expect(mapped.floating.map(\.frame) == [CGRect(x: -0.5, y: 1.25, width: 0.5, height: 0.5)],
                "the app moved a frame of the daemon's list into the pane area: \(mapped.floating.map(\.frame))")
    }
}
