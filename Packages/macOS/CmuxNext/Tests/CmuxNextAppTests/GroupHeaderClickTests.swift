import AppKit
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// Lawrence 2026-10-20: "A plain click on a group header must only expand or collapse it." A
/// click on the name, the chip or the bar toggles the group and opens no editor or menu; the
/// more button and a right-click still open them.
@MainActor @Suite(.serialized, .closesItsWindows) struct GroupHeaderClickTests {
    /// A sidebar in a window with one group, and every intent the list sends.
    final class Harness {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        let sidebar: SidebarView
        let id: GroupID
        private(set) var intents: [SidebarIntent] = []

        init() throws {
            let (sidebar, ids) = try GroupPaletteDefaultTests.sidebar([.blue])
            (self.sidebar, id) = (sidebar, ids[0])
            window.isReleasedWhenClosed = false
            window.contentView?.addSubview(sidebar)
            sidebar.list.reload(animated: false)
            sidebar.layoutSubtreeIfNeeded()
            sidebar.list.model.onIntent = { [unowned self] intent in intents.append(intent) }
        }

        var header: GroupHeaderRowView {
            get throws { try #require(sidebar.list.rowViews[.group(id)] as? GroupHeaderRowView) }
        }

        /// A plain left click at `point` in the header.
        func click(at point: NSPoint) throws {
            let header = try header
            let location = header.convert(point, to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try #require(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                                           windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                           clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
                if type == .leftMouseDown { sidebar.list.mouseDown(with: event) } else { sidebar.list.mouseUp(with: event) }
            }
        }

        var toggles: Int {
            intents.filter { if case .toggleCollapse(.group(id)) = $0 { true } else { false } }.count
        }
    }

    /// The fold of a click on the name waits out the double-click interval (a double-click
    /// renames in place, `SidebarRenameInPlaceTests`), then runs.
    @Test func aClickOnTheNameOnlyTogglesTheGroup() throws {
        let harness = try Harness()
        defer { harness.sidebar.list.groupEditor.hide(); harness.window.close() }
        let header = try harness.header
        header.layoutSubtreeIfNeeded()
        let name = header.titleFrame
        try harness.click(at: NSPoint(x: name.midX, y: name.midY))
        #expect(harness.toggles == 0, "the name's click folded before the double-click interval ended")
        #expect(harness.sidebar.list.groupNameClick.isWaiting)
        harness.sidebar.list.groupNameClick.flush()
        #expect(!harness.sidebar.list.groupEditor.isVisible, "a plain click on the group's name opened the group editor")
        #expect(harness.toggles == 1, "a plain click on the group's name did not toggle it: \(harness.intents)")
    }

    @Test func aClickOnTheBarTogglesTheGroup() throws {
        let harness = try Harness()
        defer { harness.sidebar.list.groupEditor.hide(); harness.window.close() }
        let header = try harness.header
        header.layoutSubtreeIfNeeded()
        // Between the name and the chevron.
        let x = (header.titleFrame.maxX + (header.debugDisclosure?.frame.minX ?? header.bounds.maxX)) / 2
        try harness.click(at: NSPoint(x: x, y: header.bounds.midY))
        #expect(!harness.sidebar.list.groupEditor.isVisible)
        #expect(harness.toggles == 1, "\(harness.intents)")
    }
}
