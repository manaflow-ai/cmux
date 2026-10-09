import AppKit
import CmuxNextDesign
import Testing
@testable import CmuxNextSidebar

/// A tab row under a workspace (Show Tabs Under Workspaces) is first-class
/// (rapid switching, item 3): a right-click on it asks for that tab's menu,
/// as on the tab strip, not its workspace's; a press selects the tab at once
/// and a drag hands the tab to the app's tab drag (a sidebar gap makes it a
/// new workspace, a row moves it there, a strip or pane takes it).
@MainActor @Suite struct SidebarTabRowMenuTests {
    final class Harness {
        let window: NSWindow
        let sidebar: SidebarView
        var targets: [SidebarContextTarget] = []
        var intents: [SidebarIntent] = []
        var handoffs: [SidebarTabRowDragHandoff] = []

        init() {
            var sections = fixture()
            sections[1].nodes[0] = .workspace(SidebarWorkspace(
                id: id("a"), title: "a",
                tabs: [SidebarTab(id: TabID("t1"), title: "Terminal"), SidebarTab(id: TabID("t2"), title: "Chat", kind: .agentChat)]
            ))
            let model = SidebarModel(sections: sections, activeWorkspaceID: id("a"))
            model.showWorkspaceTabs = true
            sidebar = SidebarView(model: model)
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 600), styleMask: [.borderless], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            sidebar.frame = window.contentView!.bounds
            window.contentView!.addSubview(sidebar)
            sidebar.layoutSubtreeIfNeeded()
            sidebar.list.reload(animated: false)
            model.onIntent = { [unowned self] intent in self.intents.append(intent) }
            sidebar.list.onTabRowDrag = { [unowned self] handoff in
                self.handoffs.append(handoff)
                return true
            }
            sidebar.list.contextMenuProvider = { [unowned self] target in
                self.targets.append(target)
                return nil
            }
        }

        var list: SidebarListView { sidebar.list }

        func point(_ key: SidebarRowKey) throws -> NSPoint {
            let row = try #require(list.displayed.row(for: key), "\(key) is shown")
            let frame = list.frame(for: row)
            return list.convert(NSPoint(x: frame.midX, y: frame.midY), to: nil)
        }

        func mouse(_ type: NSEvent.EventType, at point: NSPoint) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }

        func rightClick(_ key: SidebarRowKey) throws {
            let row = try #require(list.displayed.row(for: key), "\(key) is shown")
            let frame = list.frame(for: row)
            let point = list.convert(NSPoint(x: frame.midX, y: frame.midY), to: nil)
            let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [], timestamp: 0,
                                                        windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                        clickCount: 1, pressure: 1))
            _ = list.menu(for: event)
        }
    }

    @Test func aTabRowAsksForItsTabsMenu() throws {
        let harness = Harness()
        defer { harness.window.close() }
        try harness.rightClick(.tab(id("a"), TabID("t2")))
        #expect(harness.targets == [.tab(id("a"), TabID("t2"))])
    }

    @Test func theWorkspaceRowStillAsksForTheWorkspacesMenu() throws {
        let harness = Harness()
        defer { harness.window.close() }
        try harness.rightClick(.workspace(id("a")))
        #expect(harness.targets == [.workspaces([id("a")])])
    }

    @Test func aPressSelectsTheTabAtOnce() throws {
        let harness = Harness()
        defer { harness.window.close() }
        harness.list.mouseDown(with: try harness.mouse(.leftMouseDown, at: try harness.point(.tab(id("a"), TabID("t2")))))
        #expect(harness.intents.contains(.selectTab(workspace: id("a"), tab: TabID("t2"))))
    }

    @Test func draggingATabRowHandsTheTabToTheAppsDrag() throws {
        let harness = Harness()
        defer { harness.window.close() }
        let start = try harness.point(.tab(id("a"), TabID("t2")))
        harness.list.mouseDown(with: try harness.mouse(.leftMouseDown, at: start))
        harness.list.mouseDragged(with: try harness.mouse(.leftMouseDragged, at: NSPoint(x: start.x + 2, y: start.y - 30)))
        #expect(harness.handoffs.map(\.tab) == [TabID("t2")])
        #expect(harness.handoffs.first?.workspace == id("a"))
        #expect(harness.list.drag == nil, "the sidebar does not run a row drag of its own")
        // Once handed off, more movement does not hand it off again.
        harness.list.mouseDragged(with: try harness.mouse(.leftMouseDragged, at: NSPoint(x: start.x + 4, y: start.y - 60)))
        #expect(harness.handoffs.count == 1)
    }
}
