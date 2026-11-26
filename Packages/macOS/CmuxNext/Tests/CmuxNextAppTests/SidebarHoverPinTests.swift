import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// David Beyer, 2026-11-20 call: pinning a workspace by dragging it into Pinned is awkward. Every workspace row offers
/// a pin under the pointer: an outline pin (Pin Workspace) on an unpinned row, a filled one (Unpin Workspace) on a
/// pinned row, at every density; a pinned workspace's tile offers Unpin the same way. Both run Pin/Unpin Workspace
/// (`SidebarModel.workspacePin`, the action the right-click menu, the palette and the CLI run). At rest no row draws a
/// pin (Leo 2026-10-21: "no empty pin symbol by default"), and drag still pins.
@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarHoverPinTests {
    /// The harness with `pinned` reading as pinned and every toggle recorded in `toggled`.
    final class Pins {
        let harness = SidebarHomePinnedDragHarness()
        private(set) var toggled: [WorkspaceID] = []

        init(pinned: Set<WorkspaceID>) {
            harness.list.model.workspacePin = (isPinned: { pinned.contains($0) }, toggle: { [unowned self] in toggled.append($0) })
            harness.list.contextMenuProvider = { _ in NSMenu() } // a row with no menu shows no hover controls
            harness.settle()
        }

        /// Workspace row `id`, wired after the pin hook was set, hovered or not and laid out.
        func row(_ id: WorkspaceID, hovered: Bool) throws -> WorkspaceRowView {
            harness.list.setHovered(hovered ? .workspace(id) : nil)
            let row = try #require(harness.list.rowViews[.workspace(id)] as? WorkspaceRowView)
            row.wire(id, in: harness.list)
            row.needsLayout = true
            row.layoutSubtreeIfNeeded()
            return row
        }
    }

    static func shows(_ view: NSView?) -> Bool {
        guard let view else { return false }
        return !view.isHiddenOrHasHiddenAncestor && view.alphaValue > 0.01
    }

    /// The shown icon buttons in `view`'s subtree labelled `label`.
    static func buttons(labelled label: String, in view: NSView) -> [SidebarIconButton] {
        var found: [SidebarIconButton] = []
        var stack = [view]
        while let node = stack.popLast() {
            if let button = node as? SidebarIconButton, button.label == label, shows(button) { found.append(button) }
            stack.append(contentsOf: node.subviews)
        }
        return found
    }

    @Test func anUnpinnedRowOffersPinOnHoverAndRunsTheToggle() throws {
        Motion.reduceMotionOverride = true // the controls show at once instead of fading in from 0
        defer { Motion.reduceMotionOverride = nil }
        let pins = Pins(pinned: [])
        defer { pins.harness.close() }
        let id = SidebarHomePinnedDragHarness.loose[0]
        let rest = try pins.row(id, hovered: false)
        #expect(!Self.shows(rest.pinSlot.made), "an unpinned row draws a pin at rest")
        let row = try pins.row(id, hovered: true)
        #expect(Self.shows(row.pinButton), "an unpinned row offers no pin on hover")
        #expect(row.pinButton.label == CmuxNextSidebar.Strings.pinWorkspace, "the hover pin reads \(row.pinButton.label)")
        #expect(row.pinButton.accessibilityPerformPress(), "the hover pin did not press")
        #expect(pins.toggled == [id], "the hover pin ran \(pins.toggled), not Pin Workspace on \(id.rawValue)")
        // It sits left of the more button and clear of the close, and the title gives way to it.
        #expect(row.pinButton.frame.maxX <= row.moreButton.frame.minX + 0.5, "the pin overlaps the more button")
        #expect(!row.pinButton.frame.intersects(row.closeButton.frame), "the pin overlaps the close")
    }

    @Test func aPinnedRowOffersUnpinOnHover() throws {
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        let id = SidebarHomePinnedDragHarness.loose[1]
        let pins = Pins(pinned: [id])
        defer { pins.harness.close() }
        let row = try pins.row(id, hovered: true)
        #expect(Self.shows(row.pinButton), "a pinned row offers no Unpin on hover")
        #expect(row.pinButton.label == CmuxNextSidebar.Strings.unpinWorkspace, "the hover pin reads \(row.pinButton.label)")
        _ = row.pinButton.accessibilityPerformPress()
        #expect(pins.toggled == [id])
    }

    /// The hover pin shows at every density, not only on expanded rows (cx-13w3 offered Unpin there alone).
    @Test(arguments: SidebarDensity.allCases)
    func everyDensityOffersTheHoverPin(_ density: SidebarDensity) throws {
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        try SidebarGroupRailAlignmentTests.with(density, .off) {
            let pins = Pins(pinned: [SidebarHomePinnedDragHarness.loose[1]])
            defer { pins.harness.close() }
            for id in SidebarHomePinnedDragHarness.loose.prefix(2) {
                let row = try pins.row(id, hovered: true)
                #expect(Self.shows(row.pinButton), "\(density): \(id.rawValue) offers no pin on hover")
            }
        }
    }

    /// A pinned workspace's tile in the Pinned block offers Unpin beside its more button on hover.
    @Test func aPinnedTileOffersUnpinOnHover() throws {
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        let tile = SidebarHomePinnedDragHarness.pins[0]
        let workspace = WorkspaceID(tile.ref.value.replacingOccurrences(of: "local:", with: ""))
        let pins = Pins(pinned: [workspace])
        defer { pins.harness.close() }
        let view = try pins.harness.item(tile.id)
        #expect(Self.buttons(labelled: CmuxNextSidebar.Strings.unpinWorkspace, in: view).isEmpty, "a tile draws Unpin at rest")
        PinnedLikeRegularTests.hover(view, in: pins.harness)
        defer { PointerHover.setDebugPointer(nil, in: pins.harness.window) }
        let unpin = try #require(Self.buttons(labelled: CmuxNextSidebar.Strings.unpinWorkspace, in: view).first,
                                 "a hovered pinned tile offers no Unpin")
        let more = try #require(view.hoverMore)
        #expect(unpin.frame.maxX <= more.frame.minX + 0.5, "Unpin overlaps the tile's more button")
        _ = unpin.accessibilityPerformPress()
        #expect(pins.toggled == [workspace], "the tile's Unpin ran \(pins.toggled)")
    }
}
