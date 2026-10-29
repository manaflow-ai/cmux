import AppKit
@testable import CmuxNextDesign
import CmuxNextWakeups
import Testing

/// A child window's own notices start no occlusion pass (first-5s typing bench, 2026-10-28): a new tab or split
/// orders overlay panels, divider catchers and Chromium page windows as children of the shell window, each of which
/// posts occlusion and main-state notices, and every pass asks the window server for `NSApp.orderedWindows` on the
/// main thread (20-37 ms wall in a Debug build, in the first second after the new tab). Chrome's checker skips them:
/// a child window is not in `orderedWindows` and is never judged, so only a top-level window's notice can change a
/// verdict (`-windowCanTriggerOcclusionUpdates:`, components/remote_cocoa/app_shim/window_occlusion_checker_mac.mm).
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct WindowOcclusionChildWindowTests {
    final class Rig {
        let parent = Rig.window(NSRect(x: 100, y: 100, width: 600, height: 400))
        let child = Rig.window(NSRect(x: 120, y: 120, width: 200, height: 100))
        let center = NotificationCenter()
        /// AppKit's answer for the parent (false: minimized, another Space, covered by another app).
        var parentSystemVisible = true
        private(set) var orderReads = 0
        var checker: WindowOcclusionChecker!

        static func window(_ frame: NSRect) -> NSWindow {
            let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            return window
        }

        init() {
            parent.addChildWindow(child, ordered: .above)
            checker = WindowOcclusionChecker(
                windows: { [parent] in [parent] },
                orderedWindows: { [weak self, parent] in
                    self?.orderReads += 1
                    return [parent]
                },
                facts: { [weak self] window in
                    WindowOcclusionFacts(id: ObjectIdentifier(window), frame: window.frame,
                                         systemVisible: window.parent != nil || self?.parentSystemVisible ?? true, isActive: true,
                                         ancestors: window.parent.map { [ObjectIdentifier($0)] } ?? [])
                },
                isAppHidden: { false }, drawsWhenOccluded: false, center: center,
                workspaceEvents: AppEvents(center: NotificationCenter()), mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        }

        func until(_ what: String, _ condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(5)
            while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            try #require(condition(), "\(what) never happened")
        }

        /// Gives every posted pass time to run.
        func settle() async throws {
            for _ in 0..<20 { await Task.yield() }
            try await Task.sleep(for: .milliseconds(300))
        }

        func close() {
            checker.stop()
            parent.removeChildWindow(child)
            child.close()
            parent.close()
        }
    }

    @Test func aChildWindowsOcclusionAndMainNoticesStartNoPass() async throws {
        let rig = Rig()
        defer { rig.close() }
        #expect(rig.child.parent === rig.parent)
        rig.checker.start()
        try await rig.until("the first pass ran") { rig.checker.passes == 1 }
        let reads = rig.orderReads
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeMainNotification, NSWindow.didResignMainNotification] {
            rig.center.post(name: name, object: rig.child)
        }
        try await rig.settle()
        #expect(rig.checker.passes == 1, "a child window's notice started an occlusion pass")
        #expect(rig.orderReads == reads, "a child window's notice read the window server's order")
    }

    @Test func aTopLevelWindowsOcclusionNoticeStillStartsAPass() async throws {
        let rig = Rig()
        defer { rig.close() }
        rig.checker.start()
        try await rig.until("the first pass ran") { rig.checker.passes == 1 }
        rig.center.post(name: NSWindow.didChangeOcclusionStateNotification, object: rig.parent)
        try await rig.until("the parent's notice ran a pass") { rig.checker.passes == 2 }
        rig.center.post(name: NSWindow.didResignMainNotification, object: rig.parent)
        try await rig.until("the parent's main change ran a pass") { rig.checker.passes == 3 }
    }

    /// While a tracked window is off screen a child's change may be what uncovers it, so it still starts a pass.
    @Test func aChildWindowsNoticeStillStartsAPassWhileAWindowIsOffScreen() async throws {
        let rig = Rig()
        defer { rig.close() }
        rig.parentSystemVisible = false
        rig.checker.start()
        try await rig.until("the first pass ran") { rig.checker.passes == 1 }
        #expect(rig.checker.isOffScreen(rig.parent))
        rig.center.post(name: NSWindow.didChangeOcclusionStateNotification, object: rig.child)
        try await rig.until("the child's notice ran a pass") { rig.checker.passes == 2 }
    }
}
