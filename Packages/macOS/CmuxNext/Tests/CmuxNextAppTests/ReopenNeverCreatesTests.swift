import AppKit
@testable import CmuxNextApp
import CmuxNextDaemon
import Foundation
import Testing

/// Reopening the running app (a Dock click, a launcher, Finder, `open -a`, a second launch's hand-off: AppKit's
/// `applicationShouldHandleReopen`) only brings a window it has forward. Leo 2026-11-11: "double clicking from [a launcher],
/// caused this" — with the window off screen (`hasVisibleWindows` false: minimized, on another Space, or never ordered in,
/// as here), each reopen made a New Tab workspace. With no window at all, rapid reopens bring one window back, never more.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct ReopenNeverCreatesTests {
    private static func snapshot(_ services: AppServices) -> (windows: [String], workspaces: Set<String>) {
        let registry = services.windows.registry.value
        return (registry.openWindows.map(\.id).sorted(), Set(registry.openWindows.flatMap(\.workspaceIDs)))
    }

    @Test(arguments: [false, true])
    func reopeningThreeTimesKeepsEveryWindowAndTab(visible: Bool) async throws {
        let launched = try await RapidWorkspaceCreateTests.launch()
        let services = launched.services
        let window = try #require(services.windows.active)
        await RapidWorkspaceCreateTests.wait(within: .seconds(30)) { !Self.snapshot(services).workspaces.isEmpty && window.state.workspaceID != nil }
        let before = Self.snapshot(services), shown = window.state.workspaceID
        let delegate = NSApp.delegate as? AppDelegate
        for _ in 0..<3 {
            if let delegate { _ = delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: visible) } else { services.windows.reopenOrCreateWindow() }
        }
        // A create would list within this (the daemon answers in well under a second); nothing should change.
        let changed = await RapidWorkspaceCreateTests.wait(within: .seconds(3)) { Self.snapshot(services) != before || PendingWorkspaceRows.shared.rows(in: window.state.id).count > 0 }
        let after = Self.snapshot(services), shownAfter = window.state.workspaceID
        await launched.stop()

        #expect(!changed, "reopening made something: \(before) became \(after)")
        #expect(after.windows == before.windows, "windows \(before.windows) became \(after.windows)")
        #expect(after.workspaces == before.workspaces, "tabs \(before.workspaces.sorted()) became \(after.workspaces.sorted())")
        #expect(shownAfter == shown, "the window switched from \(shown ?? "nothing") to \(shownAfter ?? "nothing")")
    }

    @Test func rapidReopensWithNoWindowBringTheClosedOneBackOnce() async throws {
        let launched = try await RapidWorkspaceCreateTests.launch()
        let services = launched.services
        let window = try #require(services.windows.active)
        await RapidWorkspaceCreateTests.wait(within: .seconds(30)) { !Self.snapshot(services).workspaces.isEmpty }
        let before = Self.snapshot(services), id = window.state.id
        services.windows.userClosed(id)
        await RapidWorkspaceCreateTests.wait(within: .seconds(10)) { services.windows.registry.value.openWindows.isEmpty }
        for _ in 0..<3 { services.windows.reopenOrCreateWindow() }
        await RapidWorkspaceCreateTests.wait(within: .seconds(10)) { !services.windows.registry.value.openWindows.isEmpty }
        _ = await RapidWorkspaceCreateTests.wait(within: .seconds(3)) { Self.snapshot(services).windows.count > 1 }
        let after = Self.snapshot(services)
        await launched.stop()

        #expect(after.windows == [id], "three reopens with no window opened \(after.windows), not the closed window \(id)")
        #expect(after.workspaces == before.workspaces, "tabs \(before.workspaces.sorted()) became \(after.workspaces.sorted())")
    }
}
