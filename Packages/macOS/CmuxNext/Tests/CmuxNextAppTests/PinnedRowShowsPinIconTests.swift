import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// https://github.com/manaflow-ai/cmux/issues/63247: after pinning, the pinned row drew no pin, so it read as every
/// other row. The pin has regressed before (#42431, #49583, #56146); the last time (#52050) the sidebar region stopped
/// marking Pinned rows with `leadingPin`, so no row view below it could draw one. These tests render the real list
/// (its Pinned block through `SidebarRegionView`) and fail when any pinned row, in any state, has no visible pin.
@MainActor @Suite(.serialized, .closesItsWindows) struct PinnedRowShowsPinIconTests {
    /// The pinned rows' states: each one is a reason a row's leading column has been reworked before.
    enum RowState: String, CaseIterable {
        case plain, selected, hovered, unread, renamed, shownTabIcon, ownIcon, color
    }

    /// Redraws the harness's Pinned rows in `state`.
    static func apply(_ state: RowState, to harness: SidebarHomePinnedDragHarness) throws {
        var blocks = try #require(harness.list.blocks, "the harness list has no blocks")
        for pin in SidebarHomePinnedDragHarness.pins {
            var info = try #require(blocks.infos[pin.id], "no info for \(pin.id.rawValue)")
            switch state {
            case .plain, .selected, .hovered: break
            case .unread: info.unreadDot = true
            case .renamed: info.title = "Renamed " + info.title
            case .shownTabIcon:
                (info.symbol, info.textOnly, info.iconFromShownTab) = ("globe", false, true)
            case .ownIcon: (info.symbol, info.textOnly) = ("star", false)
            case .color: info.color = .blue
            }
            blocks.infos[pin.id] = info
        }
        harness.list.blocks = blocks
        harness.settle()
        if state == .selected { harness.list.activeTopItem = SidebarHomePinnedDragHarness.pins.first?.id; harness.settle() }
    }

    /// Asserts `row` draws its pin: configured with one, shown, not clear, and inside the row at the row's start.
    static func expectPin(_ row: SidebarItemRowView, _ state: RowState) {
        let label = "\(row.titleText) (\(state.rawValue))"
        #expect(row.info.leadingPin, "\(label): a pinned row is configured with no leading pin")
        guard let frame = row.pinSquareFrame else {
            Issue.record("\(label): a pinned row draws no pin icon (#63247)")
            return
        }
        #expect(frame.width > 0 && frame.height > 0, "\(label): the pin's frame is empty: \(frame)")
        #expect(row.bounds.contains(frame), "\(label): the pin at \(frame) is outside the row \(row.bounds)")
        #expect(frame.midX < row.bounds.width / 3, "\(label): the pin at \(frame) does not lead the row")
        var node: NSView? = row.pinSquareView
        while let view = node, view !== row.superview {
            #expect(!view.isHidden && view.alphaValue > 0.01, "\(label): the pin or a view over it is hidden or clear")
            node = view.superview
        }
    }

    @Test(arguments: RowState.allCases)
    func everyPinnedRowDrawsItsPin(_ state: RowState) throws {
        let harness = SidebarHomePinnedDragHarness()
        defer { harness.close(); PointerHover.setDebugPointer(nil, in: harness.window) }
        try Self.apply(state, to: harness)
        for pin in SidebarHomePinnedDragHarness.pins {
            let row = try harness.item(pin.id)
            if state == .hovered { PinnedLikeRegularTests.hover(row, in: harness) }
            Self.expectPin(row, state)
        }
    }

    /// The pin is the workspace's, not its shown tab's: a tab's favicon gives way to it (msg 40501), and the row's
    /// title starts after the pin, not under it.
    @Test func aPinnedRowsTitleStartsAfterItsPin() throws {
        let harness = SidebarHomePinnedDragHarness()
        defer { harness.close() }
        for pin in SidebarHomePinnedDragHarness.pins {
            let row = try harness.item(pin.id)
            let frame = try #require(row.pinSquareFrame, "\(row.titleText): a pinned row draws no pin icon (#63247)")
            #expect(row.titleFrame.minX >= frame.maxX, "\(row.titleText): the title at \(row.titleFrame) overlaps the pin at \(frame)")
        }
    }
}
