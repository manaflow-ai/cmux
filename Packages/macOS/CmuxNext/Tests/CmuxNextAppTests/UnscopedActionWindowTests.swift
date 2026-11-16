import AppKit
@testable import CmuxNextApp
import Testing
import CmuxNextTestSupport

/// Leo 2026-11-16, after `cmux action run new.newTabPage` from the CLI: "idk why you guys opened a new window".
/// An action that names no target (CLI, MCP, script) acts in the key window, else the frontmost cmux window,
/// in its current workspace, and never makes a window. With another app frontmost there is no key window:
/// the window it acts in (`WindowManager.active`, which `AppActionContext.paneController` reads for a new
/// tab and `WorkspaceHandlers.show` for a new workspace) is the one in front, not the first one opened,
/// and a new workspace's window (`targetWindow(preferring: active)`) is that open window, not a new id.
@MainActor @Suite(.closesItsWindows, .serialized) struct UnscopedActionWindowTests {
    private struct Harness {
        let services: AppServices
        let first: WindowController
        let second: WindowController

        var windows: WindowManager { services.windows }

        func close() {
            for controller in services.windows.controllers { controller.window?.close() }
            AppHarnessWindows.closeThoseThisTestOpened()
        }
    }

    /// Two windows, the first opened first; no key window (the CLI's terminal app is frontmost); both on
    /// screen as far as the manager asks (the test never orders its windows in).
    private static func harness() throws -> Harness {
        var completed = false
        defer {
            if !completed { AppHarnessWindows.closeThoseThisTestOpened() }
        }
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        services.windows.ordersWindowsIn = false
        let first = try #require(services.windows.openWindow(workspaces: ["unscoped-a1"]))
        let second = try #require(services.windows.openWindow(workspaces: ["unscoped-b1"]))
        services.keyWindowSource = { nil }
        services.windows.isOnScreen = { _ in true }
        completed = true
        return Harness(services: services, first: first, second: second)
    }

    /// What a new workspace from an unscoped run picks (`WorkspaceHandlers.show`), and whether it made a window.
    private static func newWorkspaceTarget(_ harness: Harness) -> (window: String, opened: Bool) {
        let before = harness.windows.controllers.count
        let target = harness.windows.targetWindow(preferring: harness.windows.active?.state.id)
        let isOpen = harness.windows.registry.value.window(target)?.isOpen == true
        return (target, !isOpen || harness.windows.controllers.count != before)
    }

    @Test func anUnscopedRunWithNoKeyWindowActsInTheFrontmostWindow() throws {
        let harness = try Self.harness()
        defer { harness.close() }
        let windows = harness.windows
        let shellFirst = try #require(harness.first.window), shellSecond = try #require(harness.second.window)

        windows.windowDidOrder(shellFirst, inFront: true)
        #expect(windows.active === harness.first, "the first window is in front")
        var picked = Self.newWorkspaceTarget(harness)
        #expect(picked.window == harness.first.state.id && !picked.opened, "a new workspace goes to the front window, no window made")

        windows.windowDidOrder(shellSecond, inFront: true)
        #expect(windows.active === harness.second, "the second window came to the front: an unscoped run acts there")
        picked = Self.newWorkspaceTarget(harness)
        #expect(picked.window == harness.second.state.id && !picked.opened, "a new workspace goes to the front window, no window made")
        #expect(windows.controllers.count == 2, "an unscoped run opened a window")
    }

    /// The last key window lost the front to a window ordered in without the keys (an update relaunch's
    /// restore, `--focus` under no-activate): the run acts in the window in front.
    @Test func aWindowInFrontWithoutTheKeysWinsOverTheLastKeyWindow() throws {
        let harness = try Self.harness()
        defer { harness.close() }
        let windows = harness.windows
        let shellSecond = try #require(harness.second.window)
        windows.didActivate(harness.first)
        windows.windowDidOrder(shellSecond, inFront: true)
        #expect(windows.active === harness.second, "acted in the last key window, behind the front one")
    }

    /// A window off screen (in the Dock, hidden) is never the one an unscoped run acts in, even the latest.
    @Test func aWindowOffScreenIsNeverPicked() throws {
        let harness = try Self.harness()
        defer { harness.close() }
        let windows = harness.windows
        let shellSecond = try #require(harness.second.window)
        windows.isOnScreen = { $0 !== shellSecond }
        windows.windowDidOrder(shellSecond, inFront: true)
        #expect(windows.active === harness.first, "acted in a window that is not on screen")
        let picked = Self.newWorkspaceTarget(harness)
        #expect(picked.window == harness.first.state.id && !picked.opened)
    }

    /// The key window still decides while there is one.
    @Test func theKeyWindowDecidesWhenThereIsOne() throws {
        let harness = try Self.harness()
        defer { harness.close() }
        let windows = harness.windows
        let shellFirst = try #require(harness.first.window), shellSecond = try #require(harness.second.window)
        windows.windowDidOrder(shellSecond, inFront: true)
        harness.services.keyWindowSource = { shellFirst }
        #expect(windows.active === harness.first)
    }
}
