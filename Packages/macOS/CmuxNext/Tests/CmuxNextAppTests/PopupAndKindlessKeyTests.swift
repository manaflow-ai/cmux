import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextBrowser
import CmuxNextDaemon
import CmuxNextDesign
import Testing

/// Lane 20 v2 (plans/cmux-next/windows.md): Cmd-W in a browser popup
/// closes the popup, never the selected tab of the main window behind it;
/// and a window that no owner installed through the window kit (no kind)
/// acts as a window of its own: it never runs a close or a destructive
/// action on the main window, and it never crashes the key routing.
@MainActor
@Suite(.serialized)
struct PopupAndKindlessKeyTests {
    final class Runs {
        var count = 0
    }

    /// A registered main window, last active, with `closeTab` replaced by a counter.
    private func world() throws -> (AppServices, NSWindow, Runs) {
        let services = ActionBindingCoverageTests.boundServices()
        services.windows.ordersWindowsIn = false
        services.popups.ordersPanelsIn = false
        services.daemon.store.apply(snapshot: try BrowserTabTests.tree())
        let workspace = try #require(services.daemon.store.workspaces.first)
        let main = try #require(services.windows.openWindow(workspaces: [workspace.id]))
        services.windows.didActivate(main)
        let runs = Runs()
        services.registry.bind("closeTab", invoke: { _ in runs.count += 1 })
        return (services, try #require(main.window), runs)
    }

    private func popup(over parent: NSWindow, in services: AppServices) throws -> (MockBrowserTab, NSPanel) {
        let page = MockBrowserEngine().makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://accounts.example.com/auth")))
        services.popups.open(page, request: BrowserPopupRequest(size: CGSize(width: 480, height: 640)), over: parent, openerKey: "tab-1")
        return (page, try #require(services.popups.panel(for: page)))
    }

    private func commandW(in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                      windowNumber: window.windowNumber, context: nil, characters: "w",
                                      charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13))
    }

    /// Close Tab (the menu, the palette, a rebound shortcut) while the popup
    /// is key: the window key table closes the popup and its page.
    @Test func closeTabInAPopupClosesThePopupNotTheMainWindowsTab() throws {
        let (services, main, runs) = try world()
        let (page, panel) = try popup(over: main, in: services)
        #expect(panel.windowKind == .browserPopup)
        services.keyWindowSource = { panel }
        services.registry.perform("closeTab", invocation: ActionInvocation())
        #expect(page.isClosed, "the popup's page closed")
        #expect(!services.popups.owns(page))
        #expect(runs.count == 0, "Close Tab never ran on the main window's tab")
        #expect(services.windows.controllers.count == 1)
    }

    /// Cmd-W from the keyboard while the popup is key: the same outcome
    /// (the key router's popup step, ahead of the table).
    @Test func commandWKeyInAPopupClosesThePopupNotTheMainWindowsTab() throws {
        let (services, main, runs) = try world()
        let (page, panel) = try popup(over: main, in: services)
        services.keyWindowSource = { panel }
        #expect(services.keyRouter.interceptKeyDown(try commandW(in: panel), in: panel))
        #expect(page.isClosed)
        #expect(runs.count == 0)
        #expect(services.windows.controllers.count == 1)
    }

    /// A key window without a kind and without a close button (a borderless
    /// panel no window owns): close actions do nothing, destructive content
    /// actions are refused with the window reason, the main window's tab
    /// survives.
    @Test func aKindlessBorderlessWindowNeverReachesTheMainWindow() throws {
        let (services, _, runs) = try world()
        let loose = NSPanel(contentRect: NSRect(x: -30_000, y: -30_000, width: 120, height: 80), styleMask: [.borderless],
                            backing: .buffered, defer: true)
        loose.isReleasedWhenClosed = false
        #expect(loose.windowKind == nil)
        services.keyWindowSource = { loose }
        let role = try #require(services.keyWindowRole, "a kind-less window has a role")
        #expect(role.close == .window)
        #expect(role.root === loose)
        services.registry.perform("closeTab", invocation: ActionInvocation())
        #expect(runs.count == 0, "Close Tab never ran on the main window's tab")
        let registry = services.registry
        let content = try #require(registry.descriptors.first {
            $0.isDestructive && !WindowKeyTable.contentTargets.isDisjoint(with: $0.targets) && !WindowKeyTable.isClose($0.id)
                && !WindowKeyTable.appLevel.contains($0.id)
        })
        let refusal = registry.capturingRefusal { registry.perform(content.id, invocation: ActionInvocation()) }
        #expect(refusal == MiscHandlerStrings.notInThisWindow)
        // App-level actions still run from it.
        #expect(WindowKeyTable(registry: registry).behavior(for: "commandPalette", close: role.close, overRoot: role.overRoot) == .run)
    }

    /// A titled kind-less window of its own: Cmd-W closes it, as its close button does.
    @Test func aKindlessTitledWindowClosesItself() throws {
        let (services, _, runs) = try world()
        let loose = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 300, height: 200), styleMask: [.titled, .closable],
                             backing: .buffered, defer: true)
        loose.isReleasedWhenClosed = false
        services.keyWindowSource = { loose }
        let closed = Runs()
        let token = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: loose, queue: nil) { _ in
            MainActor.assumeIsolated { closed.count += 1 }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        services.registry.perform("closeTab", invocation: ActionInvocation())
        #expect(closed.count == 1)
        #expect(runs.count == 0)
    }
}
