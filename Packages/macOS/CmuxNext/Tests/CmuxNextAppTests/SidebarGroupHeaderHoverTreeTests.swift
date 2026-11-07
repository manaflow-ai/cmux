import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Foundation
import Testing

/// HOVER COMMIT 2: a pointer crossing from one group header to the next changes paint only, as a workspace row's
/// crossing does since #37145. A header's ⋮, + and Unpin stay in the view tree once they first showed; a hover sets
/// their opacity only. Each `isHidden` flip changes the window's view tree, and AppKit pays for it in the frame's commit
/// (NSWindowUpdateLayerTree / _buildLayerTree in the sweep stalls).
@MainActor @Suite(.serialized, .closesItsWindows)
struct SidebarGroupHeaderHoverTreeTests {
    /// Two pinned group headers with a + and an Unpin, one above the other, laid out in a window.
    private func headers() -> (GroupHeaderRowView, GroupHeaderRowView, NSWindow) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 48), styleMask: .borderless,
                              backing: .buffered, defer: true)
        // `close()` would release a window the test still holds (a segfault on the fleet).
        window.isReleasedWhenClosed = false
        func make(_ id: String, y: CGFloat) -> GroupHeaderRowView {
            let gid = GroupID("grp-\(id)")
            let header = GroupHeaderRowView(key: .group(gid))
            window.contentView?.addSubview(header)
            header.frame = NSRect(x: 0, y: y, width: 240, height: 24)
            header.onEdit = {}
            header.onAdd = {}
            header.onUnpin = {}
            let group = SidebarGroup(id: gid, name: "Group \(id)", color: .blue, isPinned: true, workspaces: [])
            let row = SidebarRow(key: .group(gid), y: y, height: 24, section: .pinned, group: gid, siblingIndex: 0,
                                 parentIndex: nil, isLastInGroup: false, isCollapsed: false, childCount: 0, groupColor: nil)
            header.configure(group, row: row, animated: false)
            header.layoutSubtreeIfNeeded()
            return header
        }
        return (make("a", y: 0), make("b", y: 24), window)
    }

    /// What a crossing must not change: every view in the window and its hidden flag.
    private struct Tree: Equatable {
        var views: [ObjectIdentifier] = []
        var hidden: [Bool] = []

        init(_ root: NSView) { walk(root) }

        private mutating func walk(_ view: NSView) {
            views.append(ObjectIdentifier(view))
            hidden.append(view.isHidden)
            view.subviews.forEach { walk($0) }
        }

        func changes(to next: Tree) -> Int {
            guard views == next.views else { return abs(views.count - next.views.count) + Set(views).symmetricDifference(next.views).count }
            return zip(hidden, next.hidden).filter { $0 != $1 }.count
        }
    }

    private func cross(from: GroupHeaderRowView, to: GroupHeaderRowView, in window: NSWindow) {
        from.isHovered = false
        to.isHovered = true
        window.contentView?.layoutSubtreeIfNeeded()
    }

    private func shown(_ view: NSView) -> Bool { !view.isHidden && view.alphaValue > 0 }

    @Test func aCrossingBetweenTwoGroupHeadersChangesNoViewTree() throws {
        // Instant: a fade-out's hide would land in a later frame, after the test looked.
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        let (a, b, window) = headers()
        defer { window.close() }
        let root = try #require(window.contentView)
        // Each header shows its controls once, then the pointer leaves both.
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
            // Not vacuous: the controls did move to the header under the pointer.
            let pairs: [(String, NSView, NSView)] = [("⋮", to.moreButton, from.moreButton), ("+", to.addButton, from.addButton),
                                                     ("Unpin", to.pinButton, from.pinButton)]
            for (name, entered, left) in pairs {
                #expect(shown(entered), "the hovered header shows no \(name)")
                #expect(!shown(left), "the header the pointer left still shows its \(name)")
            }
            (from, to) = (to, from)
        }
        print("HOVER-COMMIT-2 group header tree changes per crossing: \(perCrossing)")
        #expect(perCrossing.allSatisfy { $0 == 0 }, "a group header crossing changed the window's view tree: \(perCrossing) changes per crossing")
    }

    @Test func aClearedHeaderControlTakesNoClickAndLeavesTheAccessibilityTree() throws {
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        let (a, b, window) = headers()
        defer { window.close() }
        a.isHovered = true
        window.contentView?.layoutSubtreeIfNeeded()
        cross(from: a, to: b, in: window)
        for control in [a.moreButton, a.addButton, a.pinButton] as [NSView] {
            let center = a.convert(NSPoint(x: control.frame.midX, y: control.frame.midY), to: a.superview)
            #expect(a.hitTest(center) == nil, "a cleared header control took the click")
            let children = a.accessibilityChildren() ?? []
            #expect(!children.contains { (($0 as? NSView) ?? ($0 as? NSCell)?.controlView) === control },
                    "a cleared header control stayed in the accessibility tree")
            #expect(control.isHiddenOrHasHiddenAncestor || TooltipPresenter.isClear(control), "a cleared header control would show its tooltip")
        }
        let shownMore = b.moreButton
        let center = b.convert(NSPoint(x: shownMore.frame.midX, y: shownMore.frame.midY), to: b.superview)
        #expect(b.hitTest(center) === shownMore, "the hovered header's ⋮ takes no click")
    }
}
