import AppKit
@testable import CmuxNextSidebar
import Testing

/// The detector for always-visible row chrome. #43516 gave every workspace row a screen button at rest, and it reached
/// Leo's NIGHTLY on every row (Leo, 2026-11-16: "WHAT THE HELL KIND OF BONEHEADED DECISION WAS THAT"). A plain
/// workspace row at rest (not hovered, selected, pinned, playing audio or holding sessions) shows its title and status
/// marks, never a control: close, menu and unpin come with hover, pin or selection, audio and the tree fold with their
/// state. Any new control that a plain row shows at rest fails here, whatever it is called. A control that should
/// show at rest needs a design reference and gallery variants first, then the exception goes below with Leo's words.
@MainActor @Suite(.serialized) struct SidebarRowAtRestChromeTests {
    /// Every control in the row's subtree that draws: not hidden itself or through an ancestor, not clear, not empty.
    static func visibleControls(in row: NSView) -> [NSView] {
        func walk(_ view: NSView) -> [NSView] {
            guard !view.isHidden, view.alphaValue > 0 else { return [] }
            let drawn = view is NSControl && !view.frame.isEmpty ? [view] : []
            return drawn + view.subviews.flatMap(walk)
        }
        return row.subviews.flatMap(walk)
    }

    static func describe(_ view: NSView) -> String {
        "\(type(of: view)) \(view.accessibilityIdentifier()) \(view.accessibilityLabel() ?? "")"
    }

    @Test(arguments: [240.0, 300.0, 360.0])
    func plainWorkspaceRowShowsNoControlAtRest(width: Double) throws {
        _ = NSApplication.shared
        for grouped in [false, true] {
            let model = SidebarModel(sections: SidebarScreenActionTests.examples)
            model.groupsByComputer = grouped
            let list = SidebarListView(model: model)
            list.contextMenuProvider = { _ in NSMenu() }
            list.frame = NSRect(x: 0, y: 0, width: width, height: 1000)
            list.reload(animated: false)
            list.layoutSubtreeIfNeeded()
            let rows = list.rowViews.values.compactMap { $0 as? WorkspaceRowView }
            #expect(rows.count == SidebarScreenActionTests.examples.count)
            for row in rows {
                // Hover in and out first, so controls made on hover must hide again when the pointer leaves.
                for hovered in [true, false] {
                    row.isHovered = hovered
                    row.needsLayout = true
                    row.layoutSubtreeIfNeeded()
                }
                let controls = Self.visibleControls(in: row).map(Self.describe)
                #expect(controls.isEmpty, "a plain workspace row at rest (grouped: \(grouped), width \(width)) draws \(controls)")
            }
        }
    }
}
