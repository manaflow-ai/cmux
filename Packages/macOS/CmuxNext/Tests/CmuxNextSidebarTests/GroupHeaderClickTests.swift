import AppKit
import Testing
@testable import CmuxNextSidebar

/// A click on a group header toggles it at once (cx-qno.17: no double-click
/// wait); renaming is Return on the focused header or the menu, so a double
/// click is one toggle, never a collapse and re-expand flicker.
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

    @Test func singleClickOnGroupNameTogglesAtOnce() {
        let h = Harness()
        h.click(h.namePoint(g1), count: 1)
        #expect(h.toggles == 1, "no double-click wait (cx-qno.17)")
        #expect(h.list.model.group(g1)?.isCollapsed == true)
    }

    @Test func doubleClickOnGroupNameTogglesOnceAndDoesNotRename() {
        let h = Harness()
        let point = h.namePoint(g1)
        h.click(point, count: 1)
        h.click(point, count: 2)
        #expect(h.toggles == 1, "the second click of a double click is not a second toggle")
        #expect(h.list.inlineRename.session == nil, "rename is Return or the menu")
    }

    @Test func clickOnChevronTogglesImmediately() {
        let h = Harness()
        let view = h.list.rowViews[.group(g1)] as! GroupHeaderRowView
        let local = NSPoint(x: view.disclosureFrame.midX, y: view.bounds.midY)
        let point = h.list.convert(h.list.convert(local, from: view), to: nil)
        h.click(point, count: 1)
        #expect(h.toggles == 1)
    }
}
