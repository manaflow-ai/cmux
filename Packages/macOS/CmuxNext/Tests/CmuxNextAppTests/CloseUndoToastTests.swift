import AppKit
import CmuxNextActions
import CmuxNextControl
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextDesign
import Testing

/// REOPEN-CLOSED (R102/R103): closing a tab (Cmd-W, its close button) does
/// not ask; an undo toast offers to reopen it, and Cmd-Z runs that toast
/// (TOAST-UNDO-KEY). The toast reopens exactly the tab it names, even when
/// another close happened since; a second close replaces the toast. A close
/// from automation (CLI, agents) shows no toast.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct CloseUndoToastTests {
    final class Spawns {
        var spawns: [ClosedTerminalRestorer.Spawn] = []
    }

    static func harness() async throws -> (ViewChangePermissionTests.Harness, CmuxToastCenter, Spawns) {
        let harness = try await ViewChangePermissionTests.harness()
        let toasts = CmuxToastCenter(clock: ManualClock(), host: CmuxToastHeadlessHost())
        harness.services.closedTabs?.undoToasts.toasts = toasts
        harness.services.keyRouter.undoToasts = toasts
        let spawns = Spawns()
        harness.services.closedTabs?.restorer = ClosedTerminalRestorer(
            isAvailable: { true }, project: { _, _, _ in throw DaemonError.notConnected },
            spawn: { spawn in spawns.spawns.append(spawn); return SurfaceID(rawValue: 99) })
        return (harness, toasts, spawns)
    }

    static func waitUntil(_ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let end = clock.now.advanced(by: .seconds(10))
        while !condition(), clock.now < end { try await clock.sleep(for: .milliseconds(20)) } // test-only wait
    }

    static func commandZ(_ window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber,
                         context: nil, characters: "z", charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6)!
    }

    @Test func closingATabOffersAnUndoToastAndCommandZReopensIt() async throws {
        let (harness, toasts, spawns) = try await Self.harness()
        defer { harness.stop() }
        let window = try #require(harness.window.window)
        let pane = try #require(harness.pane)
        let tabs = harness.tabCount
        let closed = try #require(pane.stripModel.selectedID)
        let index = try #require(pane.orderedIDs.firstIndex(of: closed))
        // Cmd-W from the keyboard: a user close.
        #expect(harness.services.registry.perform("closeTab", invocation: ActionInvocation(origin: .user)))
        try await Self.waitUntil { harness.tabCount == tabs - 1 && !toasts.toasts(in: window).isEmpty }
        let toast = try #require(toasts.toasts(in: window).first)
        #expect(toast.action?.isUndo == true)
        #expect(toast.message != "toast.tabClosed", "the message is localized")
        #expect(harness.services.keyRouter.interceptKeyDown(Self.commandZ(window), in: window), "Cmd-Z runs the toast")
        try await Self.waitUntil { !spawns.spawns.isEmpty }
        #expect(spawns.spawns.first?.pane == pane.pane.handle)
        #expect(spawns.spawns.first?.index == index, "the closed tab comes back at its place")
        #expect(toasts.toasts(in: window).isEmpty, "the toast ends once used")
    }

    @Test func aSecondCloseReplacesTheToastAndItReopensThatTab() async throws {
        let (harness, toasts, spawns) = try await Self.harness()
        defer { harness.stop() }
        let window = try #require(harness.window.window)
        let pane = try #require(harness.pane)
        let ids = pane.orderedIDs
        try #require(ids.count == 2)
        pane.handle(.close(ids[0], source: .mouse))
        try await Self.waitUntil { toasts.toasts(in: window).count == 1 }
        let first = try #require(toasts.toasts(in: window).first)
        pane.handle(.close(ids[1], source: .mouse))
        try await Self.waitUntil { toasts.toasts(in: window).first.map { $0 != first } ?? false }
        #expect(toasts.toasts(in: window).count == 1, "one close toast at a time")
        #expect(toasts.runUndo(in: window))
        try await Self.waitUntil { !spawns.spawns.isEmpty }
        // The first close moved the second tab to index 0: the toast names that tab.
        #expect(spawns.spawns.map(\.index) == [0], "the second tab, at its own place")
        #expect(harness.services.closedTabs?.records.count == 1, "the first closed tab is still in the history")
    }

    @Test func aCloseFromAutomationShowsNoToast() async throws {
        let (harness, toasts, _) = try await Self.harness()
        defer { harness.stop() }
        let window = try #require(harness.window.window)
        let tabs = harness.tabCount
        try await ViewChangePermissionTests.run(harness, "closeTab", origin: "cli")
        try await Self.waitUntil { harness.tabCount == tabs - 1 }
        for _ in 0..<20 { await Task.yield() }
        #expect(toasts.toasts(in: window).isEmpty)
    }
}
