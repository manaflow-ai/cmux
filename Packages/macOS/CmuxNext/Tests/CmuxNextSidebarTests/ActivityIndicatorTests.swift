import AppKit
import Testing
@testable import CmuxNextSidebar

/// The agent spinner stops animating while its window is occluded.
@MainActor @Suite struct ActivityIndicatorTests {
    @Test func policyPausesWhenOccludedOrReduceMotion() {
        #expect(ActivityIndicatorView.animation(for: .running, inWindow: true, windowVisible: true, reduceMotion: false) == .spin)
        #expect(ActivityIndicatorView.animation(for: .needsInput, inWindow: true, windowVisible: true, reduceMotion: false) == .pulse)
        #expect(ActivityIndicatorView.animation(for: .running, inWindow: true, windowVisible: false, reduceMotion: false) == nil)
        #expect(ActivityIndicatorView.animation(for: .running, inWindow: false, windowVisible: true, reduceMotion: false) == nil)
        #expect(ActivityIndicatorView.animation(for: .running, inWindow: true, windowVisible: true, reduceMotion: true) == nil)
        #expect(ActivityIndicatorView.animation(for: .error, inWindow: true, windowVisible: true, reduceMotion: false) == nil)
    }

    @Test func listPausesAndResumesRowSpinners() throws {
        var sections = fixture()
        sections[1].nodes[0] = .workspace({ var ws = w("a"); ws.activity = .running; return ws }())
        let sidebar = SidebarView(model: SidebarModel(sections: sections, activeWorkspaceID: id("a")))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 400), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        sidebar.frame = window.contentView!.bounds
        window.contentView!.addSubview(sidebar)
        sidebar.layoutSubtreeIfNeeded()
        sidebar.list.reload(animated: false)
        let list = sidebar.list
        list.setWindowVisible(true)
        let indicators = list.subviews.flatMap { $0.subviews.compactMap { $0 as? ActivityIndicatorView } }
        let running = try #require(indicators.first { $0.activity == .running })
        #expect(running.runningAnimation == .spin)
        list.setWindowVisible(false)
        #expect(running.runningAnimation == nil)
        list.setWindowVisible(true)
        #expect(running.runningAnimation == .spin)
    }
}
