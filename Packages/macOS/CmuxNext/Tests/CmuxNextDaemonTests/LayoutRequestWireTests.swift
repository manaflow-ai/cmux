import Foundation
import Testing
@testable import CmuxNextDaemon

/// The Requests/Layout family on the wire: the exact JSON line each request sends (the envelope's `id`
/// and `cmd` included), the capability that gates it, and how its reply decodes. The family moves from
/// hand-written Swift to types generated from cmux-tui/spec/sdk-schema.json; these hold the JSON the
/// same through that move.
struct LayoutRequestWireTests {
    private func line(_ request: some DaemonRequest, id: UInt64 = 1) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: WireCoding.encodeRequest(request, id: id))
    }

    private func envelope(_ command: String, _ fields: [String: JSONValue]) -> JSONValue {
        .object(fields.merging(["id": .number(1), "cmd": .string(command)]) { $1 })
    }

    /// A gate on the request is one every daemon the app connects to serves (the `required` tier), or one
    /// the request names because an older daemon may lack it.
    private func expectGate<R: DaemonRequest>(_: R.Type, optional: String?) {
        if let optional {
            #expect(R.requiredCapability == optional)
            #expect(DaemonCapability.optional.contains(optional))
        } else if let gate = R.requiredCapability {
            #expect(DaemonCapability.required.contains(gate))
        }
    }

    @Test func aDividerDragSendsTheSplitRatioAndTransaction() throws {
        #expect(try line(SetSplitRatioRequest(split: SplitID(rawValue: 4), ratio: 0.25)) ==
            envelope("set-split-ratio", ["split": .number(4), "ratio": .number(0.25)]))
        #expect(try line(SetSplitRatioRequest(split: SplitID(rawValue: 4), ratio: 0.5, transaction: 9)) ==
            envelope("set-split-ratio", ["split": .number(4), "ratio": .number(0.5), "transaction": .number(9)]))
        expectGate(SetSplitRatioRequest.self, optional: nil)
    }

    @Test func aColumnWidthDragSendsThePaneWidthAndTransaction() throws {
        #expect(try line(SetColumnWidthRequest(pane: PaneID(rawValue: 3), width: 0.75, transaction: 2)) ==
            envelope("set-viewport-pane-width", ["pane": .number(3), "width": .number(0.75), "transaction": .number(2)]))
        #expect(try line(SetColumnWidthRequest(pane: PaneID(rawValue: 3), width: 1)) ==
            envelope("set-viewport-pane-width", ["pane": .number(3), "width": .number(1)]))
        expectGate(SetColumnWidthRequest.self, optional: nil)
    }

    @Test func anUndoSendsTheRevisionToConfirmOnlyWhenConfirming() throws {
        #expect(try line(UndoLayoutRequest(pane: PaneID(rawValue: 3))) == envelope("undo-layout", ["pane": .number(3)]))
        #expect(try line(UndoLayoutRequest(pane: PaneID(rawValue: 3), revision: 12, confirmClose: true)) ==
            envelope("undo-layout", ["pane": .number(3), "revision": .number(12), "confirm_close": .bool(true)]))
        expectGate(UndoLayoutRequest.self, optional: nil)
    }

    @Test func anUndoReplyDecodesBothShapes() throws {
        let undone = try JSONDecoder().decode(UndoLayoutRequest.Response.self, from: Data(#"{"undone":true,"screen":5,"revision":13}"#.utf8))
        #expect(undone == UndoLayoutRequest.Response(undone: true, screen: ScreenID(rawValue: 5), revision: 13))
        let confirm = try JSONDecoder().decode(UndoLayoutRequest.Response.self, from: Data(
            #"{"undone":false,"screen":5,"revision":13,"confirmation_required":true,"closes_panes":[3,4]}"#.utf8))
        #expect(confirm.confirmationRequired == true)
        #expect(confirm.closesPanes == [PaneID(rawValue: 3), PaneID(rawValue: 4)])
    }

    @Test func aRowHeightChangeSendsEveryRowOfTheColumn() throws {
        let heights = [RowHeightValue(row: RowID(rawValue: 1), height: 400), RowHeightValue(row: RowID(rawValue: 2), height: 600)]
        let rows: JSONValue = .array([
            .object(["row": .number(1), "height": .number(400)]), .object(["row": .number(2), "height": .number(600)]),
        ])
        #expect(try line(SetRowHeightsRequest(column: ColumnID(rawValue: 8), heights: heights, fit: true, transaction: 5)) ==
            envelope("set-row-heights", ["column": .number(8), "heights": rows, "fit": .bool(true), "transaction": .number(5)]))
        #expect(try line(SetRowHeightsRequest(column: ColumnID(rawValue: 8), heights: heights, fit: false)) ==
            envelope("set-row-heights", ["column": .number(8), "heights": rows, "fit": .bool(false)]))
        expectGate(SetRowHeightsRequest.self, optional: "rows-v1")
    }

    @Test func aDockSendsItsEdgeModeRoleAndPin() throws {
        let home = DockSnapshot(edge: .left, mode: .docked, role: .agentChat, isPinned: true)
        #expect(try line(SetColumnDockRequest(pane: PaneID(rawValue: 3), dock: home, pinned: true, transaction: 4)) ==
            envelope("set-column-dock", [
                "pane": .number(3), "dock": .bool(true), "edge": .string("left"), "mode": .string("docked"),
                "role": .string("agent_chat"), "pinned": .bool(true), "transaction": .number(4),
            ]))
        #expect(try line(SetColumnDockRequest(pane: PaneID(rawValue: 3), dock: DockSnapshot(edge: .right, mode: .overlay))) ==
            envelope("set-column-dock", ["pane": .number(3), "dock": .bool(true), "edge": .string("right"), "mode": .string("overlay")]))
        expectGate(SetColumnDockRequest.self, optional: "dock-columns-v1")
    }

    @Test func anUndockSendsOnlyThePaneAndFalse() throws {
        #expect(try line(SetColumnDockRequest(pane: PaneID(rawValue: 3), dock: nil)) ==
            envelope("set-column-dock", ["pane": .number(3), "dock": .bool(false)]))
    }

    @Test func aSwapNamesADirectionOrAPaneNeverBoth() throws {
        #expect(try line(SwapPaneRequest(pane: PaneID(rawValue: 3), target: .direction(.up))) ==
            envelope("swap-pane", ["pane": .number(3), "dir": .string("up")]))
        #expect(try line(SwapPaneRequest(pane: PaneID(rawValue: 3), target: .pane(PaneID(rawValue: 6)))) ==
            envelope("swap-pane", ["pane": .number(3), "target": .number(6)]))
        expectGate(SwapPaneRequest.self, optional: nil)
    }

    @Test func aZoomSendsThePaneAndModeOnlyWhenSet() throws {
        #expect(try line(ZoomPaneRequest(pane: nil)) == envelope("zoom-pane", [:]))
        #expect(try line(ZoomPaneRequest(pane: PaneID(rawValue: 3), mode: .off)) ==
            envelope("zoom-pane", ["pane": .number(3), "mode": .string("off")]))
        expectGate(ZoomPaneRequest.self, optional: nil)
    }

    @Test func aZoomReplyNamesTheZoomedPaneOrNone() throws {
        let zoomed = try JSONDecoder().decode(ZoomPaneRequest.Response.self, from: Data(#"{"pane":3,"zoomed":true,"zoomed_pane":3}"#.utf8))
        #expect(zoomed.pane == PaneID(rawValue: 3))
        #expect(zoomed.zoomed)
        #expect(zoomed.zoomedPane == PaneID(rawValue: 3))
        let none = try JSONDecoder().decode(ZoomPaneRequest.Response.self, from: Data(#"{"pane":3,"zoomed":false,"zoomed_pane":null}"#.utf8))
        #expect(!none.zoomed)
        #expect(none.zoomedPane == nil)
    }

    @Test func theDirectionsAreTheirWireNames() {
        #expect([PaneDirection.left, .right, .up, .down].map(\.rawValue) == ["left", "right", "up", "down"])
        #expect([ColumnMoveDirection.left, .right].map(\.rawValue) == ["left", "right"])
    }
}
