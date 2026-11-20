import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Foundation
import Testing

/// HOVER COMMIT: a pointer crossing from one sidebar row to the next changes paint only (Chrome's model: hover is a
/// style change, never a tree change). A row's hover controls (the x, the ⋮) exist once they first showed; after that
/// a crossing only changes their layer's opacity. An `isHidden` flip, a subview added or removed, or a tracking area
/// added or removed changes the window's view tree, and AppKit pays for that in the frame's commit: the sweep stalls
/// of steps f105684e and 909bfc85 were NSWindowUpdateLayerTree / _buildLayerTree, a whole-window default-button walk
/// and SidebarIconButton.updateLayer (its viewDidHide repaint), not the hover handler.
@MainActor @Suite(.serialized, .closesItsWindows)
struct SidebarHoverCrossingTreeTests {
    /// Two closable rows with a menu, one above the other, laid out in a window.
    private func rows() -> (WorkspaceRowView, WorkspaceRowView, NSWindow) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 220, height: 56), styleMask: .borderless,
                              backing: .buffered, defer: true)
        // `close()` would release a window the test still holds (a segfault on the fleet).
        window.isReleasedWhenClosed = false
        func make(_ id: String, y: CGFloat) -> WorkspaceRowView {
            let ws = SidebarWorkspace(id: WorkspaceID(id), title: "Workspace \(id)", lastActivity: Date())
            let content = SidebarLayoutOptions().rowContent(ws, machine: nil)
            let row = SidebarRow(key: .workspace(ws.id), y: y, height: 28, section: .pinned, group: nil, siblingIndex: 0,
                                 parentIndex: nil, isLastInGroup: false, isCollapsed: false, childCount: 0, groupColor: nil,
                                 content: content)
            let view = WorkspaceRowView(key: row.key)
            window.contentView?.addSubview(view)
            view.frame = NSRect(x: 0, y: y, width: 220, height: 28)
            view.configure(ws, row: row, badgeStyle: .corner)
            view.onClose = {}
            view.onMore = {}
            view.layoutSubtreeIfNeeded()
            return view
        }
        return (make("a", y: 0), make("b", y: 28), window)
    }

    /// What a crossing must not change: every view in the window, its hidden flag and its tracking areas.
    private struct Tree: Equatable {
        var views: [ObjectIdentifier] = []
        var hidden: [Bool] = []
        var trackingAreas = 0

        init(_ root: NSView) { walk(root) }

        private mutating func walk(_ view: NSView) {
            views.append(ObjectIdentifier(view))
            hidden.append(view.isHidden)
            trackingAreas += view.trackingAreas.count
            view.subviews.forEach { walk($0) }
        }

        /// The changes from `self` to `next`: views added or removed, hidden flips, tracking areas added or removed.
        func changes(to next: Tree) -> Int {
            guard views == next.views else { return abs(views.count - next.views.count) + Set(views).symmetricDifference(next.views).count }
            return zip(hidden, next.hidden).filter { $0 != $1 }.count + abs(trackingAreas - next.trackingAreas)
        }
    }

    /// The pointer leaves `from` for `to`, then the frame's layout pass runs.
    private func cross(from: WorkspaceRowView, to: WorkspaceRowView, in window: NSWindow) {
        from.isHovered = false
        to.isHovered = true
        window.contentView?.layoutSubtreeIfNeeded()
    }

    private func shown(_ view: NSView?) -> Bool { view.map { !$0.isHidden && $0.alphaValue > 0 } ?? false }

    @Test func aCrossingBetweenTwoRowsChangesNoViewTree() throws {
        let (a, b, window) = rows()
        defer { window.close() }
        let root = try #require(window.contentView)
        // Each row shows its controls once (they are made on first show, REOPEN-F7), then the pointer leaves both.
        a.isHovered = true
        root.layoutSubtreeIfNeeded()
        cross(from: a, to: b, in: window)
        b.isHovered = false
        root.layoutSubtreeIfNeeded()
        a.isHovered = true
        root.layoutSubtreeIfNeeded()

        var perCrossing: [Int] = []
        var (from, to) = (a, b)
        for _ in 0..<6 {
            let before = Tree(root)
            cross(from: from, to: to, in: window)
            perCrossing.append(before.changes(to: Tree(root)))
            // Not vacuous: the controls did move to the row under the pointer.
            #expect(shown(to.closeSlot.made) && shown(to.moreSlot.made), "the hovered row shows no x and ⋮")
            #expect(!shown(from.closeSlot.made) && !shown(from.moreSlot.made), "the row the pointer left still shows its x or ⋮")
            (from, to) = (to, from)
        }
        print("HOVER-COMMIT tree changes per crossing: \(perCrossing)")
        #expect(perCrossing.allSatisfy { $0 == 0 }, "a hover crossing changed the window's view tree: \(perCrossing) changes per crossing")
    }

    @Test func aClearedControlTakesNoClickAndLeavesTheAccessibilityTree() throws {
        let (a, b, window) = rows()
        defer { window.close() }
        a.isHovered = true
        window.contentView?.layoutSubtreeIfNeeded()
        cross(from: a, to: b, in: window)
        let close = try #require(a.closeSlot.made), more = try #require(a.moreSlot.made)
        for control in [close, more] {
            let center = a.convert(NSPoint(x: control.frame.midX, y: control.frame.midY), to: a.superview)
            #expect(a.hitTest(center) == nil, "a cleared control took the click")
            let children = a.accessibilityChildren() ?? []
            #expect(!children.contains { (($0 as? NSView) ?? ($0 as? NSCell)?.controlView) === control },
                    "a cleared control stayed in the accessibility tree")
            #expect(control.isHiddenOrHasHiddenAncestor || TooltipPresenter.isClear(control), "a cleared control would show its tooltip")
        }
        // The row's own tooltip (a clipped title, calm mode's crumb) still shows over its cleared controls.
        a.themedToolTip = "Row tip"
        let rowTip = try #require(TooltipTracker.whole(of: a))
        let controlTips = [close, more].compactMap { TooltipTracker.whole(of: $0) }
        #expect(!controlTips.isEmpty, "the row's controls have no tooltip to test")
        #expect(TooltipPresenter.pick([rowTip] + controlTips) === rowTip, "a cleared control hid the row's tooltip under it")
        let shownClose = try #require(b.closeSlot.made)
        let center = b.convert(NSPoint(x: shownClose.frame.midX, y: shownClose.frame.midY), to: b.superview)
        #expect(b.hitTest(center) === shownClose, "the hovered row's x takes no click")
        #expect(!TooltipPresenter.isClear(shownClose), "the hovered row's x shows no tooltip")
    }

    /// The pointer moves down the column of x's: it enters the next row's x while that x is still clear (the row's
    /// layout shows it in the frame after the move). Once it shows, the x's own tooltip is the one waiting.
    @Test func aControlShownUnderThePointerGetsItsTooltip() throws {
        let (a, b, window) = rows()
        // The shared presenter keeps its panel and only orders it out; close it too (`.closesItsWindows`).
        defer { window.close(); TooltipPresenter.shared.dismiss(); TooltipPresenter.shared.panel.close() }
        let root = try #require(window.contentView)
        b.isHovered = true
        root.layoutSubtreeIfNeeded()
        cross(from: b, to: a, in: window)
        let close = try #require(b.closeSlot.made)
        let tip = try #require(TooltipTracker.whole(of: close))
        #expect(TooltipPresenter.isClear(close))
        TooltipPresenter.shared.enter(tip)
        cross(from: a, to: b, in: window)
        #expect(!TooltipPresenter.isClear(close), "the hovered row's x did not show")
        #expect(TooltipPresenter.shared.candidate === tip, "the x the pointer is on waits for no tooltip")
    }
}
