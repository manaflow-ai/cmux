import AppKit
import Testing

@testable import CmuxWindowing

@MainActor
@Suite("AccessibilityWindowCache")
struct AccessibilityWindowCacheTests {
    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        return window
    }

    private func windows(_ value: Any?) -> [NSWindow]? {
        value as? [NSWindow]
    }

    private func expectWindowsEqual(
        _ actual: Any?,
        _ expected: [NSWindow],
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        guard let actualWindows = windows(actual) else {
            Issue.record("Expected NSWindow array", sourceLocation: sourceLocation)
            return
        }
        #expect(actualWindows.count == expected.count, sourceLocation: sourceLocation)
        guard actualWindows.count == expected.count else { return }
        for (lhs, rhs) in zip(actualWindows, expected) {
            #expect(lhs === rhs, sourceLocation: sourceLocation)
        }
    }

    @Test("repeated .windows queries reuse a single hierarchy build until state changes")
    func repeatedWindowsQueriesReuseSingleHierarchyBuildUntilStateChanges() {
        let firstWindow = makeWindow()
        let secondWindow = makeWindow()
        defer {
            firstWindow.orderOut(nil)
            secondWindow.orderOut(nil)
        }

        let cache = AccessibilityWindowCache()
        let state = AccessibilityWindowCache.StateToken(windows: [firstWindow, secondWindow])
        var buildCount = 0

        let firstValue = cache.value(for: .windows, stateToken: state) {
            buildCount += 1
            return .init(windows: [firstWindow, secondWindow])
        }
        let secondValue = cache.value(for: .windows, stateToken: state) {
            Issue.record("Expected cached snapshot for repeated state")
            return .init(windows: [])
        }

        expectWindowsEqual(firstValue, [firstWindow, secondWindow])
        expectWindowsEqual(secondValue, [firstWindow, secondWindow])
        #expect(buildCount == 1, "Expected a single hierarchy build for repeated AX queries with no invalidation")
    }

    @Test("a changed state token invalidates the cached hierarchy snapshot")
    func changedStateTokenInvalidatesCachedHierarchySnapshot() {
        let window = makeWindow()
        let otherWindow = makeWindow()
        defer {
            window.orderOut(nil)
            otherWindow.orderOut(nil)
        }

        let cache = AccessibilityWindowCache()
        let initialState = AccessibilityWindowCache.StateToken(windows: [window])
        let updatedState = AccessibilityWindowCache.StateToken(windows: [window, otherWindow])
        var buildCount = 0

        _ = cache.value(for: .windows, stateToken: initialState) {
            buildCount += 1
            return .init(windows: [window])
        }
        let updatedWindowsValue = cache.value(for: .windows, stateToken: updatedState) {
            buildCount += 1
            return .init(windows: [window, otherWindow])
        }

        expectWindowsEqual(updatedWindowsValue, [window, otherWindow])
        #expect(buildCount == 2, "Expected the cache to rebuild once after the hierarchy token changes")
    }

    @Test("non-.windows attributes stay passthrough")
    func nonWindowsAttributesStayPassthrough() {
        let cache = AccessibilityWindowCache()

        for attribute: NSAccessibility.Attribute in [.children, .visibleChildren, .mainWindow, .focusedWindow] {
            switch cache.resolve(attribute: attribute, application: NSApp) {
            case .passthrough:
                break
            case .handled:
                Issue.record("Expected \(attribute.rawValue) to fall back to AppKit")
            }
        }
    }

    @Test("NSWindow.willCloseNotification invalidates the cache")
    func windowCloseNotificationInvalidatesCache() {
        let window = makeWindow()
        defer { window.orderOut(nil) }

        let center = NotificationCenter()
        let cache = AccessibilityWindowCache(notificationCenter: center)
        let state = AccessibilityWindowCache.StateToken(windows: [window])
        var buildCount = 0

        _ = cache.value(for: .windows, stateToken: state) {
            buildCount += 1
            return .init(windows: [window])
        }
        center.post(name: NSWindow.willCloseNotification, object: window)
        _ = cache.value(for: .windows, stateToken: state) {
            buildCount += 1
            return .init(windows: [window])
        }

        #expect(buildCount == 2, "Expected NSWindow.willCloseNotification to invalidate the cache")
    }
}
