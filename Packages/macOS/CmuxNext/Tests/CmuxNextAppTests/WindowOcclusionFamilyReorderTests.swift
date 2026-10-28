import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextWakeups
import Testing

/// An order that changes neither the key nor the main window (`.bringForward` while
/// the app is inactive, `.orderBack`, a restack) posts no notification the families' checker observes.
/// The window manager's order report (`WindowManager.windowDidOrder`) starts its pass, so the window
/// now in front is seen again and the one now behind is occluded.
@MainActor @Suite struct WindowOcclusionFamilyReorderTests {
    @Test func aReorderWithoutAKeyChangeFlipsTheFamilies() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let first = Self.window(), second = Self.window()
        defer { first.close(); second.close() }
        let firstFamily = WindowOcclusionFamily.of(first), secondFamily = WindowOcclusionFamily.of(second)
        // Two same-size windows; AppKit says both are visible and neither is key (the app is inactive).
        let stack = Stack(frontToBack: [first, second])
        services.windowOcclusionFamilies = WindowOcclusionChecker.feedingFamilies(
            windows: { [first, second] }, orderedWindows: { stack.frontToBack },
            facts: { WindowOcclusionFacts(id: ObjectIdentifier($0), frame: CGRect(x: 0, y: 0, width: 800, height: 600)) },
            isAppHidden: { false }, drawsWhenOccluded: false, center: NotificationCenter(),
            workspaceEvents: services.workspaceEvents, mainWork: services.mainWork)
        defer { services.windowOcclusionFamilies?.stop() }
        try await Self.until("the first pass occludes the back window") { secondFamily.isOccluded && !firstFamily.isOccluded }

        stack.frontToBack = [second, first]
        services.windows.windowDidOrder(second, inFront: true)
        try await Self.until("the reorder flips both families") { !secondFamily.isOccluded && firstFamily.isOccluded }
        #expect(secondFamily.flips == 2)
        #expect(firstFamily.flips == 1)
    }

    /// The app's window order, which the test changes as `WindowActivation` would.
    @MainActor final class Stack {
        var frontToBack: [NSWindow]
        init(frontToBack: [NSWindow]) { self.frontToBack = frontToBack }
    }

    static func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    static func until(_ what: @autoclosure () -> String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition(), "\(what()) never happened")
    }
}
