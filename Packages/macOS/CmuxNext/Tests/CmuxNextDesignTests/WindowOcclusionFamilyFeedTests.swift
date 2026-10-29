import AppKit
@testable import CmuxNextDesign
import CmuxNextWakeups
import Testing

/// Chrome's checker pass feeds every window's ``WindowOcclusionFamily``. macOS does
/// not report a window covered by a same-size window of the same app (crbug.com/883031), so a fake
/// system state that says both windows are visible still leaves the back one occluded.
@MainActor @Suite struct WindowOcclusionFamilyFeedTests {
    let front = Self.window()
    let back = Self.window()

    static func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    /// A checker over `front` above `back` whose facts come from `frame` (AppKit says both are visible;
    /// the front one is the key window), fed into their families.
    func makeChecker(frame: @escaping @MainActor (NSWindow) -> CGRect) -> WindowOcclusionChecker {
        let ordered = [self.front, self.back], key = self.front
        return WindowOcclusionChecker.feedingFamilies(
            windows: { ordered }, orderedWindows: { ordered },
            facts: { window in
                WindowOcclusionFacts(id: ObjectIdentifier(window), frame: frame(window), systemVisible: true, isActive: window === key)
            },
            isAppHidden: { false }, drawsWhenOccluded: false, center: NotificationCenter(),
            workspaceEvents: AppEvents(center: NotificationCenter()), mainWork: MainWorkScheduler(budget: MainFrameBudget()))
    }

    @Test func theBackOfTwoSameSizeWindowsIsOccludedWhileTheSystemSaysVisible() {
        let frontFamily = WindowOcclusionFamily.of(front), backFamily = WindowOcclusionFamily.of(back)
        var frontFrame = CGRect(x: 0, y: 0, width: 800, height: 600)
        let key = self.front
        let checker = makeChecker { $0 === key ? frontFrame : CGRect(x: 0, y: 0, width: 800, height: 600) }
        checker.update()
        #expect(backFamily.isOccluded)
        #expect(!frontFamily.isOccluded)

        // The front window shrinks: part of the back one shows again.
        frontFrame = CGRect(x: 0, y: 0, width: 400, height: 600)
        checker.update()
        #expect(!backFamily.isOccluded)
        #expect(backFamily.flips == 2)
        checker.stop()
    }

    /// Only windows that have a family are judged: a window no reader follows costs nothing.
    @Test func windowsWithoutAFamilyAreNotJudged() {
        let backFamily = WindowOcclusionFamily.of(back)
        let checker = makeChecker { _ in CGRect(x: 0, y: 0, width: 800, height: 600) }
        checker.update()
        #expect(backFamily.isOccluded)
        #expect(WindowOcclusionFamily.installed(on: front) == nil)
        checker.stop()
        #expect(!backFamily.isOccluded, "a stopped checker reports every window back on screen")
    }
}
