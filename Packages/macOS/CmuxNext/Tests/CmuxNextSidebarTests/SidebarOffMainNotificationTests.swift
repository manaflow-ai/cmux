import AppKit
import CmuxNextDesign
import Foundation
import Testing
@testable import CmuxNextSidebar

/// Posts `name` from a background thread and returns when the post returned.
private func postOffMain(_ name: Notification.Name, object: AnyObject?, on center: NotificationCenter = .default) async {
    let post = OffMainPost(name: name, object: object, center: center)
    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
        Thread.detachNewThread {
            post.send()
            done.resume()
        }
    }
}

/// One post handed to a background thread (`Thread.detachNewThread`, never
/// main); the object is only passed through.
private nonisolated final class OffMainPost: @unchecked Sendable {
    let name: Notification.Name
    let object: AnyObject?
    let center: NotificationCenter
    init(name: Notification.Name, object: AnyObject?, center: NotificationCenter) {
        self.name = name
        self.object = object
        self.center = center
    }
    func send() { center.post(name: name, object: object) }
}

/// Waits on main (bounded) until `done` holds.
@MainActor
private func waitOnMain(_ done: () -> Bool) async {
    let deadline = ContinuousClock.now + .seconds(5)
    while !done(), ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(10))
    }
}

/// AppKit and WebKit post notifications off the main thread too. A selector
/// observer whose target is main-actor isolated trapped the whole process
/// there (signal 5, Swift's isolation check; #18771). The observer must
/// survive an off-main post and do its work on main
/// (plans/cmux-next/crash-elimination.md, P1b).
@MainActor @Suite(.serialized)
struct SidebarOffMainNotificationTests {
    func makeSidebar() -> (SidebarView, NSWindow) {
        var sections = fixture()
        sections[1].nodes[0] = .workspace({ var ws = w("a"); ws.activity = .busy; ws.agentWorking = true; return ws }())
        let sidebar = SidebarView(model: SidebarModel(sections: sections, activeWorkspaceID: id("a")))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 400), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = sidebar
        sidebar.layoutSubtreeIfNeeded()
        sidebar.list.reload(animated: false)
        return (sidebar, window)
    }

    /// The list follows its window's occlusion (object: that window): a
    /// notice posted off main pauses or resumes the row indicators on main.
    @Test func anOcclusionChangeOffMainReachesTheRowIndicatorsOnMain() async throws {
        let (sidebar, window) = makeSidebar()
        defer { window.close() }
        let list = sidebar.list
        let indicator = try #require(list.subviews.flatMap { $0.subviews.compactMap { $0 as? StatusIndicatorView } }.first)
        let expected = window.occlusionState.contains(.visible)
        list.setWindowVisible(!expected)
        #expect(indicator.isWindowVisible == !expected)

        await postOffMain(NSWindow.didChangeOcclusionStateNotification, object: window)
        await waitOnMain { indicator.isWindowVisible == expected }
        #expect(indicator.isWindowVisible == expected)
    }

    /// A scroller style change (object: nil) posted off main restyles the
    /// sidebar's list on main.
    @Test(.disabled("posts a scroll notice off main on NotificationCenter.default, where AppKit's own NSScrollView observer re-tiles off main and a main-actor document view traps the whole run (SIGTRAP, run 37906639937); post on an injected center instead"))
    func aScrollerStyleChangeOffMainRestylesTheSidebarOnMain() async {
        let saved = SystemScrollers.preferredStyleOverride
        defer { SystemScrollers.preferredStyleOverride = saved }
        let (sidebar, window) = makeSidebar()
        defer { window.close() }
        let target: NSScroller.Style = sidebar.scrollView.scrollerStyle == .legacy ? .overlay : .legacy
        SystemScrollers.preferredStyleOverride = target

        await postOffMain(NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
        await waitOnMain { sidebar.scrollView.scrollerStyle == target }
        #expect(sidebar.scrollView.scrollerStyle == target)
    }

    /// A clip move posted off main realizes rows on main without trapping.
    @Test(.disabled("posts a scroll notice off main on NotificationCenter.default, where AppKit's own NSScrollView observer re-tiles off main and a main-actor document view traps the whole run (SIGTRAP, run 37906639937); post on an injected center instead"))
    func aClipMovePostedOffMainDoesNotTrap() async {
        let (sidebar, window) = makeSidebar()
        defer { window.close() }
        await postOffMain(NSView.boundsDidChangeNotification, object: sidebar.scrollView.contentView)
        await postOffMain(NSView.frameDidChangeNotification, object: sidebar.scrollView.contentView)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            OperationQueue.main.addOperation { done.resume() }
        }
        #expect(sidebar.list.window === window)
    }
}
