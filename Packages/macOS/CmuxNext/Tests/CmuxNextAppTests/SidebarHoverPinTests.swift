import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// Design council dp-1824f397ce, "The pin goes where the pinned thing goes" (Leo 2026-11-21: "the pin button does not
/// make sense. you expect this to be the pinned thing."): Pin and Unpin live in the row's right-click menu beside
/// Archive, and the per-row hover pin goes. No workspace row and no pinned tile draws a Pin or Unpin button, at rest or
/// under the pointer, at any density; dragging into Pinned still pins.
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

    /// Every shown Pin or Unpin button in `view`'s subtree.
    static func pins(in view: NSView) -> [SidebarIconButton] {
        buttons(labelled: CmuxNextSidebar.Strings.pinWorkspace, in: view) + buttons(labelled: CmuxNextSidebar.Strings.unpinWorkspace, in: view)
    }

    @Test(arguments: SidebarDensity.allCases)
    func noRowOffersAHoverPin(_ density: SidebarDensity) throws {
        Motion.reduceMotionOverride = true // the controls show at once instead of fading in from 0
        defer { Motion.reduceMotionOverride = nil }
        try SidebarGroupRailAlignmentTests.with(density, .off) {
            let pins = Pins(pinned: [SidebarHomePinnedDragHarness.loose[1]])
            defer { pins.harness.close() }
            for id in SidebarHomePinnedDragHarness.loose.prefix(2) {
                let rest = try pins.row(id, hovered: false)
                #expect(Self.pins(in: rest).isEmpty, "\(density): \(id.rawValue) draws a pin at rest")
                let row = try pins.row(id, hovered: true)
                #expect(Self.shows(row.moreButton), "\(density): \(id.rawValue) shows no hover controls, so the check proves nothing")
                #expect(Self.pins(in: row).isEmpty, "\(density): \(id.rawValue) offers a pin on hover")
            }
            #expect(pins.toggled.isEmpty)
        }
    }

    @Test func aPinnedTileOffersNoHoverUnpin() throws {
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        let tile = SidebarHomePinnedDragHarness.pins[0]
        let workspace = WorkspaceID(tile.ref.value.replacingOccurrences(of: "local:", with: ""))
        let pins = Pins(pinned: [workspace])
        defer { pins.harness.close() }
        let view = try pins.harness.item(tile.id)
        PinnedNoHoverCloseTests.hover(view, in: pins.harness)
        defer { PointerHover.setDebugPointer(nil, in: pins.harness.window) }
        #expect(Self.shows(view.hoverMore), "the hovered tile shows no more button, so the check proves nothing")
        #expect(Self.pins(in: view).isEmpty, "a hovered pinned tile offers Unpin")
    }
}
