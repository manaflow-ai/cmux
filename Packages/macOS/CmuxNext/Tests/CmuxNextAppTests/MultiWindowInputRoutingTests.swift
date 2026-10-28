import AppKit
@testable import CmuxNextApp
import CmuxNextFocusUI
import CmuxNextTestSupport
import Foundation
import Testing

/// Lawrence 2026-10-23: "i click a workspace in one window, and it triggers it in the other
/// window… sometimes i type in one window of cmux, but the text appears in another window".
/// With two or more cmux windows open, a click or a key in window A acts in window A only:
/// - the window an action targets during an event's dispatch is the window the event came from,
///   even while AppKit still reports another window as key (after Cmd-Tab, a stale key record);
/// - a key typed into one cmux window never reaches another cmux window that became key since;
/// - a workspace a person picks in window A's sidebar shows in window A;
/// - a New Tab hold never takes the key window from another window;
/// - keys the daemon gives back go only to a terminal of the window they were typed in.
@MainActor @Suite(.serialized, .closesItsWindows) struct MultiWindowInputRoutingTests {
    private struct Harness {
        let services: AppServices
        let a: WindowController
        let b: WindowController

        func close() {
            for controller in services.windows.controllers { controller.window?.close() }
        }
    }

    private static func harness() throws -> Harness {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        services.windows.ordersWindowsIn = false
        let a = try #require(services.windows.openWindow(workspaces: ["mw-a1"]))
        let b = try #require(services.windows.openWindow(workspaces: ["mw-b1", "mw-b2"]))
        #expect(a !== b)
        return Harness(services: services, a: a, b: b)
    }

    // MARK: Clicks and keys act in the window they came from

    /// AppKit still names window B key (the app is activating after Cmd-Tab, or the key record is
    /// stale) while a click in window A is dispatched: whatever the click runs targets window A.
    @Test func theActiveWindowDuringAnEventIsTheEventsWindow() throws {
        let harness = try Self.harness()
        defer { harness.close() }
        let windows = harness.services.windows
        let shellA = try #require(harness.a.window), shellB = try #require(harness.b.window)
        harness.services.keyWindowSource = { shellB }
        #expect(windows.active === harness.b, "outside an event the key window decides")
        let during = windows.dispatching(eventFrom: shellA) { windows.active }
        #expect(during === harness.a, "a click in window A ran its action in window \(during === harness.b ? "B" : "?")")
        #expect(windows.active === harness.b, "the event's scope ends with its dispatch")
    }

    /// An action the event runs that makes another window key on purpose (New Window, Select Next
    /// Window: `WindowActivation.show`) is followed: that window is the active one for the rest of
    /// the dispatch. AppKit making the window that was key at deactivation key again while the app
    /// activates (no `WindowActivation` order) is not: the click still acts in its own window.
    @Test func onlyAKeyChangeTheEventMadeIsFollowed() throws {
        let harness = try Self.harness()
        defer { harness.close() }
        let windows = harness.services.windows
        let shellA = try #require(harness.a.window), shellB = try #require(harness.b.window)
        harness.services.keyWindowSource = { nil }  // the app is not active (Cmd-Tab away)
        let restored = windows.dispatching(eventFrom: shellA) { () -> WindowController? in
            harness.services.keyWindowSource = { shellB }  // activation gives B the keys back
            return windows.active
        }
        #expect(restored === harness.a, "a click in window A acted in window B after the app activated")
        harness.services.keyWindowSource = { shellA }
        let asked = windows.dispatching(eventFrom: shellA) { () -> WindowController? in
            harness.services.keyWindowSource = { shellB }
            windows.windowDidOrder(shellB, inFront: true)  // the action brought B forward
            return windows.active
        }
        #expect(asked === harness.b)
    }

    /// A key-down typed into window A while window B became key (a late `makeKey`, a stale key
    /// record) is dropped, never delivered to B. Keys within one window's family (its Chromium page
    /// window, a sheet) go on.
    @Test func aKeyTypedInOneWindowNeverReachesAnother() throws {
        let harness = try Self.harness()
        defer { harness.close() }
        let shellA = try #require(harness.a.window), shellB = try #require(harness.b.window)
        let keyGuard = CrossWindowInputGuard(windows: harness.services.windows)
        #expect(keyGuard.dropsKey(eventWindow: shellA, keyWindow: shellB), "a key typed in A reached B")
        #expect(keyGuard.dropsKey(eventWindow: shellB, keyWindow: shellA), "a key typed in B reached A")
        #expect(!keyGuard.dropsKey(eventWindow: shellA, keyWindow: shellA))
        let page = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.borderless], backing: .buffered, defer: true)
        page.isReleasedWhenClosed = false
        shellA.addChildWindow(page, ordered: .above)
        defer { shellA.removeChildWindow(page); page.close() }
        #expect(!keyGuard.dropsKey(eventWindow: shellA, keyWindow: page), "A's own page window takes A's keys")
        #expect(!keyGuard.dropsKey(eventWindow: page, keyWindow: shellA))
        #expect(keyGuard.dropsKey(eventWindow: page, keyWindow: shellB), "a key typed in A's page reached B")
        #expect(!keyGuard.dropsKey(eventWindow: nil, keyWindow: shellB), "a key with no window is not judged here")
    }

    /// A workspace a person picks in window A's sidebar (a pinned item listing a workspace that
    /// window B shows) shows in window A; window B is left as it was.
    @Test func aSidebarPickInWindowAShowsTheWorkspaceInWindowA() throws {
        let harness = try Self.harness()
        defer { harness.close() }
        let windows = harness.services.windows
        let bShown = harness.b.state.workspaceID
        windows.show(workspaceID: "mw-b2", in: harness.a.state, from: .thisWindow)
        #expect(windows.registry.value.owner(of: "mw-b2") == harness.a.state.id, "the workspace stayed in window B")
        #expect(harness.a.state.workspaceID == "mw-b2", "window A does not show the workspace picked in it")
        #expect(harness.b.state.workspaceID == bShown, "window B changed its shown workspace for a click in window A")
    }

    /// A request from elsewhere (a notification, the CLI) still shows the workspace where it lives.
    @Test func aRequestFromElsewhereShowsTheWorkspaceWhereItLives() throws {
        let harness = try Self.harness()
        defer { harness.close() }
        let windows = harness.services.windows
        windows.show(workspaceID: "mw-b2", in: harness.a.state)
        #expect(windows.registry.value.owner(of: "mw-b2") == harness.b.state.id)
        #expect(harness.b.state.workspaceID == "mw-b2")
    }

    // MARK: Nothing takes the keyboard from another window

    /// Cmd-T in window A, then the person moves to window B: when A's New Tab field gets ready,
    /// A does not take the key window back from B (the keys typed in B would then go to A).
    @Test func aNewTabHoldNeverTakesTheKeyWindowFromAnotherWindow() {
        let make = { () -> NSWindow in
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.borderless], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            return window
        }
        let a = make(), b = make(), page = make()
        a.addChildWindow(page, ordered: .above)
        defer { a.removeChildWindow(page); for window in [a, b, page] { window.close() } }
        #expect(!NewTabInputCoordinator.mayTakeKey(a, keyWindow: b), "window A took the keyboard from window B")
        #expect(NewTabInputCoordinator.mayTakeKey(a, keyWindow: page), "A takes the keys back from its own page window")
        #expect(NewTabInputCoordinator.mayTakeKey(a, keyWindow: nil))
    }

    /// Keys the daemon gives back from a creation in window A wait for a terminal of window A; a
    /// focus settle in window B never takes them.
    @Test func givenBackKeysGoOnlyToTheirOwnWindow() {
        let input = GivenBackInput(limit: .seconds(60))
        var inA = Data(), inB = Data()
        input.deliver(adding: Data("ls\r".utf8), window: "A", to: nil)
        input.deliver(window: "B", to: { inB.append($0) })
        #expect(inB.isEmpty, "keys typed in window A reached a terminal of window B")
        input.deliver(window: "A", to: { inA.append($0) })
        #expect(inA == Data("ls\r".utf8))
        // Keys of no known window are never typed anywhere.
        input.deliver(adding: Data("rm".utf8), window: nil, to: { inB.append($0) })
        #expect(inB.isEmpty)
    }
}
