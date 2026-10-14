import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
@testable import CmuxNextTabs
import Testing

/// POLISH audit, batch 2 (cx-2grmt): under Reduce Motion a closed workspace's sidebar row and a
/// closed tab vanished in one frame, and new ones popped in: their fade ran inside the movement
/// spring, which Reduce Motion skips. The rows and tabs take their places at once and the change
/// crossfades (motion.md rule 7).
@MainActor @Suite(.serialized) struct ReduceMotionListFadeTests {
    /// The crossfades running on `layer`.
    static func crossfades(_ layer: CALayer?) -> [CATransition] {
        (layer?.animationKeys() ?? []).compactMap { layer?.animation(forKey: $0) as? CATransition }
    }

    @Test func aClosedWorkspaceRowCrossfadesUnderReduceMotion() throws {
        // Synchronous from here to the reset: the override is process-wide.
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        let model = SidebarMock.makeModel()
        let list = SidebarListView(model: model)
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 240, height: 900), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        window.contentView = list
        list.frame = NSRect(x: 0, y: 0, width: 240, height: 900)
        list.reload(animated: false)
        let section = try #require(model.sections.firstIndex { $0.id == .machine(.local) })
        let node = try #require(model.sections[section].nodes.firstIndex {
            if case let .workspace(ws) = $0 { ws.id != model.activeWorkspaceID } else { false }
        })
        guard case let .workspace(closed) = model.sections[section].nodes[node] else { return }
        #expect(list.rowViews[.workspace(closed.id)] != nil)

        model.sections[section].nodes.remove(at: node)
        list.reload(animated: true)
        #expect(list.rowViews[.workspace(closed.id)] == nil)
        #expect(!Self.crossfades(list.layer).isEmpty, "the closed row vanished in one frame")
    }

    @Test func aClosedTabCrossfadesUnderReduceMotion() throws {
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        let tabs = (0..<3).map { TabItem(id: TabID("tab\($0)"), title: "Tab \($0)") }
        let model = TabStripModel(tabs: tabs, selectedID: TabID("tab0"))
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 600, height: 40), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        let strip = TabStripView(model: model)
        strip.frame = NSRect(x: 0, y: 0, width: 600, height: TabStripView.preferredHeight)
        window.contentView = strip
        strip.layoutSubtreeIfNeeded()

        model.tabs.removeLast()
        strip.sync(fromModel: true)
        #expect(strip.cells[TabID("tab2")] == nil)
        #expect(!Self.crossfades(strip.tabsClip.layer).isEmpty, "the closed tab vanished in one frame")
    }

    /// Review of #19938: a tab synced without the strip's springs (`animating: false`, at full
    /// width at once) crossfades in under Reduce Motion too.
    @Test func aNewTabFromCmdTCrossfadesUnderReduceMotion() throws {
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        let model = TabStripModel(tabs: [TabItem(id: TabID("tab0"), title: "Tab 0")], selectedID: TabID("tab0"))
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 600, height: 40), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        let strip = TabStripView(model: model)
        strip.frame = NSRect(x: 0, y: 0, width: 600, height: TabStripView.preferredHeight)
        window.contentView = strip
        strip.layoutSubtreeIfNeeded()

        model.tabs.append(TabItem(id: TabID("tab1"), title: "New Tab"))
        model.selectedID = TabID("tab1")
        strip.sync(fromModel: true, animating: false)
        #expect(strip.cells[TabID("tab1")] != nil)
        #expect(!Self.crossfades(strip.tabsClip.layer).isEmpty, "Cmd-T's tab popped in")
    }
}
