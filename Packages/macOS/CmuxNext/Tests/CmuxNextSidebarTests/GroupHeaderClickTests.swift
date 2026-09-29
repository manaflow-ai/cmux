import AppKit
import Testing
@testable import CmuxNextSidebar

/// Double-clicking a group header renames it without collapsing and
/// re-expanding the group first (the flicker).
@MainActor @Suite struct GroupHeaderClickTests {
    final class Harness {
        let window: NSWindow
        let sidebar: SidebarView
        var intents: [SidebarIntent] = []

        init() {
            let model = SidebarModel(sections: fixture(), activeWorkspaceID: id("a"))
            sidebar = SidebarView(model: model)
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 600), styleMask: [.borderless], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            sidebar.frame = window.contentView!.bounds
            window.contentView!.addSubview(sidebar)
            sidebar.layoutSubtreeIfNeeded()
            sidebar.list.reload(animated: false)
            model.onIntent = { [unowned self] intent in
                self.intents.append(intent)
                model.apply(intent)
            }
        }

        var list: SidebarListView { sidebar.list }

        var toggles: Int {
            intents.filter { if case .toggleCollapse = $0 { true } else { false } }.count
        }

        /// A point on the group's name, in window coordinates.
        func namePoint(_ group: GroupID) -> NSPoint {
            let row = list.displayed.row(for: .group(group))!
            let frame = list.frame(for: row)
            return list.convert(NSPoint(x: frame.minX + frame.width * 0.5, y: frame.midY), to: nil)
        }

        func click(_ point: NSPoint, count: Int) {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                               windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                               clickCount: count, pressure: 1)!
                if type == .leftMouseDown { list.mouseDown(with: event) } else { list.mouseUp(with: event) }
            }
        }
    }

    @Test func doubleClickOnGroupNameRenamesWithoutToggling() {
        let h = Harness()
        let point = h.namePoint(g1)
        h.click(point, count: 1)
        h.click(point, count: 2)
        #expect(h.toggles == 0)
        #expect(h.list.rename?.key == .group(g1))
        h.list.endRename(commit: false)
    }
}
