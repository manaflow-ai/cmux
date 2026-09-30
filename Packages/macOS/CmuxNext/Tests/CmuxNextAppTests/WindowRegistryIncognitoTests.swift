import CmuxNextDaemon
import Foundation
@testable import CmuxNextApp
import Testing

/// Incognito windows (user decision 2026-09-30): nothing moves between an
/// incognito window and a normal one, closing an incognito window discards
/// its workspaces, and incognito windows are never saved.
struct WindowRegistryIncognitoTests {
    /// Normal window n lists w1 w2; incognito window i lists p1 (most recent).
    private func mixed() -> WindowRegistry {
        var registry = WindowRegistry()
        registry.openWindow(id: "n", workspaceIDs: ["w1", "w2"])
        registry.markIncognito("i")
        registry.openWindow(id: "i", workspaceIDs: ["p1"])
        return registry
    }

    @Test func aMarkedWindowOpensIncognito() {
        let registry = mixed()
        #expect(registry.isIncognito("i"))
        #expect(!registry.isIncognito("n"))
        #expect(registry.violations().isEmpty)
    }

    @Test func closingAnIncognitoWindowDiscardsItsWorkspaces() {
        var registry = mixed()
        let changes = registry.close("i")
        #expect(registry.window("i") == nil)
        #expect(changes.discarded == ["p1"])
        #expect(changes.moved.isEmpty)
        #expect(registry.window("n")?.workspaceIDs == ["w1", "w2"])
        #expect(!registry.isIncognito("i"))
        #expect(registry.violations().isEmpty)
    }

    /// Until the daemon closes them, discarded workspaces are orphans that
    /// no window may take: a normal window would show incognito pages.
    @Test func discardedWorkspacesNeverBecomeOrphansOfANormalWindow() {
        var registry = mixed()
        registry.close("i")
        #expect(registry.discarding == ["p1"])
        let still = registry.reconcile(live: ["w1", "w2", "p1"], dead: [], fallbackWindow: "unused")
        #expect(still.moved.isEmpty)
        #expect(registry.owner(of: "p1") == nil)
        registry.reconcile(live: ["w1", "w2"], dead: ["p1"], fallbackWindow: "unused")
        #expect(registry.discarding.isEmpty)
    }

    /// The only incognito window closes for good (never a closed record
    /// that a Dock click would reopen).
    @Test func theOnlyWindowBeingIncognitoStillCloses() {
        var registry = WindowRegistry()
        registry.markIncognito("i")
        registry.openWindow(id: "i", workspaceIDs: ["p1"])
        let changes = registry.close("i")
        #expect(registry.windows.isEmpty)
        #expect(changes.discarded == ["p1"])
        #expect(registry.reopen() == nil)
    }

    @Test func aClosedNormalWindowNeverHandsItsWorkspacesToAnIncognitoWindow() {
        var registry = mixed()
        registry.openWindow(id: "m", workspaceIDs: ["w3"])
        registry.activate("i")
        let changes = registry.close("m")
        #expect(changes.moved == ["n": ["w3"]])
        #expect(registry.window("i")?.workspaceIDs == ["p1"])

        // With only incognito windows left, the last normal window stays
        // registered (closed), keeping its workspaces restorable.
        var only = mixed()
        only.close("n")
        #expect(only.window("n")?.isOpen == false)
        #expect(only.window("n")?.workspaceIDs == ["w1", "w2"])
        #expect(only.window("i")?.workspaceIDs == ["p1"])
    }

    @Test func workspacesNeverMoveBetweenIncognitoAndNormalWindows() {
        var registry = mixed()
        #expect(registry.crossesIncognito(["w1"], to: "i"))
        #expect(registry.crossesIncognito(["p1"], to: "n"))
        #expect(!registry.crossesIncognito(["w2"], to: "n"))
        let before = registry
        #expect(registry.move(["w1"], to: "i").isEmpty)
        #expect(registry.move(["p1"], to: "n").isEmpty)
        #expect(registry == before)
    }

    @Test func tearingOffAnIncognitoWorkspaceMakesAnIncognitoWindow() {
        var registry = mixed()
        registry.openWindow(id: "i", workspaceIDs: ["p2"])
        registry.openWindow(id: "t", workspaceIDs: ["p2"])
        #expect(registry.isIncognito("t"))
        #expect(registry.window("t")?.workspaceIDs == ["p2"])

        // A tear-off that mixes both kinds is refused.
        let before = registry
        #expect(registry.openWindow(id: "x", workspaceIDs: ["w1", "p1"]).isEmpty)
        #expect(registry == before)
        // A window marked incognito never takes a normal window's workspace.
        registry.markIncognito("y")
        #expect(registry.openWindow(id: "y", workspaceIDs: ["w1"]).isEmpty)
        #expect(registry.window("y") == nil)
    }

    @Test func orphansNeverLandInAnIncognitoWindow() {
        var registry = mixed()
        registry.activate("i")
        let changes = registry.reconcile(live: ["w1", "w2", "p1", "w9"], dead: [], fallbackWindow: "unused")
        #expect(changes.moved == ["n": ["w9"]])

        // Only incognito windows are open: an orphan opens a normal window.
        var incognitoOnly = WindowRegistry()
        incognitoOnly.markIncognito("i")
        incognitoOnly.openWindow(id: "i", workspaceIDs: ["p1"])
        let opened = incognitoOnly.reconcile(live: ["p1", "w9"], dead: [], fallbackWindow: "fresh")
        #expect(opened.moved == ["fresh": ["w9"]])
        #expect(!incognitoOnly.isIncognito("fresh"))
    }

    /// New Incognito Window claims its new workspace for a marked window id
    /// before the daemon reports it; reconcile opens that window incognito.
    @Test func aClaimedWorkspaceOpensItsMarkedIncognitoWindow() {
        var registry = WindowRegistry()
        registry.openWindow(id: "n", workspaceIDs: ["w1"])
        registry.markIncognito("i")
        let changes = registry.reconcile(live: ["w1", "p1"], dead: [], placements: ["p1": "i"], fallbackWindow: "unused")
        #expect(changes.moved == ["i": ["p1"]])
        #expect(registry.isIncognito("i"))
    }

    @Test func incognitoWindowsAreNeverSaved() {
        let registry = mixed()
        #expect(registry.record("i", state: nil, order: 0) == nil)
        #expect(registry.record("n", state: nil, order: 1) != nil)
    }
}
