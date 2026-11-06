import AppKit
@testable import CmuxNextApp
import CmuxNextFocusUI
import Foundation
import Testing
import CmuxNextTestSupport

/// Lawrence 2026-10-23: "i click a workspace in one window, and it triggers it in the other
/// window… sometimes i type in one window of cmux, but the text appears in another window".
/// With two or more cmux windows open, a click or a key in window A acts in window A only:
/// - the window an action targets during an event's dispatch is the window the event came from,
///   even while AppKit still reports another window as key (after Cmd-Tab, a stale key record);
/// - a key typed into one cmux window never reaches another cmux window that became key since;
/// - a workspace a person picks in window A's sidebar shows in window A;
/// - a New Tab hold never takes the key window from another window;
/// - keys the daemon gives back go only to a terminal of the window they were typed in.
@MainActor @Suite(.closesItsWindows, .serialized) struct MultiWindowInputRoutingTests {
    private struct Harness {
        let services: AppServices
        let a: WindowController
        let b: WindowController

        func close() {
            for controller in services.windows.controllers { controller.window?.close() }
            // What the app opened for its windows while the test ran (their overlay panels).
            AppHarnessWindows.closeThoseThisTestOpened()
        }
    }

    private static func harness() throws -> Harness {
        var completed = false
        defer {
            if !completed { AppHarnessWindows.closeThoseThisTestOpened() }
        }
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        services.windows.ordersWindowsIn = false
        let a = try #require(services.windows.openWindow(workspaces: ["mw-a1"]))
        let b = try #require(services.windows.openWindow(workspaces: ["mw-b1", "mw-b2"]))
        #expect(a !== b)
        completed = true
        return Harness(services: services, a: a, b: b)
    }

    /// The app's ``CrossWindowInputGuard`` over `windows` (as `CrossWindowInputGuard.drops(keyTypedInto:keyWindow:router:)` builds it).
    private static func keyGuard(_ windows: WindowManager) -> CrossWindowInputGuard {
        CrossWindowInputGuard { [weak windows] in windows?.owner(of: $0)?.state.id }
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
        let keyGuard = Self.keyGuard(harness.services.windows)
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

    /// A key typed into cmux window A and run again later (a creation hold's held key) never reaches a window no cmux
    /// window owns that became key since: a floating panel (the Quick Agent Chat, the Chief pet's reply box).
    /// A creation hold runs its held keys again with `NSApp.sendEvent`, which goes to the key window; a held line typed in
    /// A went into the panel's field, and its Return sent it to an agent (review of #35275; the dogfood v2.2.3 class). A
    /// key typed into that panel itself still goes on, and so do A's keys for a panel over A (A's own).
    @Test func aHeldKeyNeverReachesAPanelNoCmuxWindowOwns() throws {
        let harness = try Self.harness()
        defer { harness.close() }
        let shellA = try #require(harness.a.window)
        let keyGuard = Self.keyGuard(harness.services.windows)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 80), styleMask: [.titled, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        #expect(keyGuard.owner(panel) == nil, "the test's panel is owned by a cmux window")
        let heldSincePanel = CrossWindowInputGuard.HeldRun(keyWindow: panel) // the held keys' run began while the panel was key
        #expect(keyGuard.dropsKey(eventWindow: shellA, keyWindow: panel, heldRun: heldSincePanel), "a held key typed in A reached a panel no cmux window owns")
        #expect(!keyGuard.dropsKey(eventWindow: panel, keyWindow: panel), "a key typed into the panel did not reach it")
        #expect(!keyGuard.dropsKey(eventWindow: nil, keyWindow: panel), "a key with no window is not judged here")
        // A panel over A (a child window) is A's own: A's keys go on there.
        shellA.addChildWindow(panel, ordered: .above)
        defer { shellA.removeChildWindow(panel) }
        #expect(!keyGuard.dropsKey(eventWindow: shellA, keyWindow: panel, heldRun: heldSincePanel), "A's own panel did not take A's keys")
    }

    /// A window no cmux window owns takes a key of A only when it became key after the key's moment: a key typed now
    /// reaches a panel the person opened and typed into at once; a held key reaches one that a key of its own run made key
    /// (Start Agent's key, then its line: review of #35832), never one that was key when its run began. Neither reaches
    /// window B, and a held key still reaches its own window and a panel over it.
    @Test func aPanelTakesAKeyOnlyWhenItBecameKeyAfterTheKeysMoment() throws {
        let harness = try Self.harness()
        defer { harness.close() }
        let shellA = try #require(harness.a.window), shellB = try #require(harness.b.window)
        let keyGuard = Self.keyGuard(harness.services.windows)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 80), styleMask: [.titled, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        let heldSincePanel = CrossWindowInputGuard.HeldRun(keyWindow: panel), heldSinceA = CrossWindowInputGuard.HeldRun(keyWindow: shellA)
        #expect(!keyGuard.dropsKey(eventWindow: shellA, keyWindow: panel), "a key typed now did not reach the panel the person opened")
        #expect(keyGuard.dropsKey(eventWindow: shellA, keyWindow: panel, heldRun: heldSincePanel), "a held key reached a panel that was key when its run began")
        #expect(!keyGuard.dropsKey(eventWindow: shellA, keyWindow: panel, heldRun: heldSinceA), "a held key did not follow a panel its own run made key")
        #expect(keyGuard.dropsKey(eventWindow: shellA, keyWindow: shellB), "a key typed now in A reached B")
        #expect(keyGuard.dropsKey(eventWindow: shellA, keyWindow: shellB, heldRun: heldSinceA), "a held key typed in A reached B")
        #expect(!keyGuard.dropsKey(eventWindow: shellA, keyWindow: shellA, heldRun: heldSincePanel), "a held key did not reach its own window")
        shellA.addChildWindow(panel, ordered: .above)
        defer { shellA.removeChildWindow(panel) }
        #expect(!keyGuard.dropsKey(eventWindow: shellA, keyWindow: panel, heldRun: heldSincePanel), "a held key did not reach a panel over its window")
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
