import AppKit
import CmuxNextDesign
import Testing
@testable import CmuxNextSidebar

/// The row status indicator (the shared `StatusIndicatorView`) stops
/// animating while its window is occluded.
@MainActor @Suite(.serialized) struct ActivityIndicatorTests {
    @Test func listPausesAndResumesRowSpinners() throws {
        let design = DesignSettings.shared
        let savedSpeed = design.animationSpeed
        let savedReduceMotion = Motion.reduceMotionOverride
        defer {
            design.animationSpeed = savedSpeed
            if Motion.reduceMotionOverride == savedReduceMotion {
                // Force the shared appearance cache to observe the restored
                // animation speed even when the override value is unchanged.
                Motion.reduceMotionOverride = true
            }
            Motion.reduceMotionOverride = savedReduceMotion
        }
        design.animationSpeed = .fast
        // Refresh the shared appearance cache after pinning the process-wide
        // motion inputs. The transition is synchronous and uses no delay.
        Motion.reduceMotionOverride = true
        Motion.reduceMotionOverride = false
        var sections = fixture()
        // An agent turn: rows show busy work only for an agent (`working`) or with `progress` on.
        sections[1].nodes[0] = .workspace({ var ws = w("a"); ws.activity = .busy; ws.agentWorking = true; return ws }())
        let sidebar = SidebarView(model: SidebarModel(sections: sections, activeWorkspaceID: id("a")))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 400), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        sidebar.frame = window.contentView!.bounds
        window.contentView!.addSubview(sidebar)
        sidebar.layoutSubtreeIfNeeded()
        sidebar.list.reload(animated: false)
        let list = sidebar.list
        list.setWindowVisible(true)
        let indicators = list.subviews.flatMap { $0.subviews.compactMap { $0 as? StatusIndicatorView } }
        let running = try #require(indicators.first { $0.state == .busy })
        #expect(running.indicator.runningAnimation != nil)
        list.setWindowVisible(false)
        #expect(running.indicator.runningAnimation == nil)
        list.setWindowVisible(true)
        #expect(running.indicator.runningAnimation != nil)
    }

    @Test func collapsedGroupShowsTheStrongestChildStatus() {
        var group = SidebarGroup(id: GroupID("g"), name: "g", workspaces: [w("a"), w("b"), w("c")])
        group.workspaces[0].activity = .busy
        group.workspaces[1].activity = .busy(progress: 0.5)
        #expect(group.aggregateActivity == .busy(progress: 0.5))
        group.workspaces[2].activity = .waiting
        #expect(group.aggregateActivity == .waiting)
    }

    @Test func spokenStatusCoversEveryState() {
        #expect(Strings.activity(.idle) == nil)
        for state: StatusIndicatorState in [.busy, .busy(progress: 0.25), .paused(progress: nil), .waiting, .error, .success] {
            #expect(Strings.activity(state)?.isEmpty == false)
        }
    }
}

/// The indicator's layers are sublayers AppKit does not manage; they must
/// follow the window's backing scale or they render 1x and blurry on Retina.
@MainActor @Suite struct ActivityIndicatorScaleTests {
    final class ScaledWindow: NSWindow {
        var scale: CGFloat = 2
        override var backingScaleFactor: CGFloat { scale }
    }

    @Test func indicatorFollowsBackingScale() {
        let window = ScaledWindow(contentRect: NSRect(x: 0, y: 0, width: 40, height: 40), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let indicator = StatusIndicatorView(frame: NSRect(x: 0, y: 0, width: 14, height: 14))
        window.contentView!.addSubview(indicator)
        indicator.configure(.busy)
        indicator.layoutSubtreeIfNeeded()
        #expect(indicator.indicator.contentsScale == 2)
        window.scale = 1
        indicator.viewDidChangeBackingProperties()
        indicator.layoutSubtreeIfNeeded()
        #expect(indicator.indicator.contentsScale == 1)
    }
}
