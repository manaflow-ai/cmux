import AppKit
import CmuxNextActions
import CmuxNextBridge
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextDesign
@testable import CmuxNextSettings
@testable import CmuxNextSidebar
import Foundation
import Testing

/// New Workspace in New Group from the CLI, MCP or a script (a terminal, so the create waits for the daemon) places
/// itself: its group forms at `workspaces.newPlacement`, and the daemon's create lists the workspace first below Home
/// under the default `top`. Its pending row drew after every row from the press (no slot and no setting rule: the
/// end of the loose rows), then sprang to the top once the daemon listed it. Every layout the list applies must show
/// the new row only at the top.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct NewInNewGroupRowSlotTests {
    @Test func newWorkspaceInNewGroupDrawsItsRowOnlyAtTheTop() async throws {
        let launched = try await RapidWorkspaceCreateTests.launch(sessionEvents: true)
        let services = launched.services
        let url = launched.root.appendingPathComponent("cmux.json")
        try Data(#"{"workspaces":{"newPlacement":"top"}}"#.utf8).write(to: url)
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        await settings.reload()
        services.settings = settings
        try #require(services.settings?.snapshot.newWorkspacePlacement == .top)
        let window = try #require(services.windows.active?.state.id)
        let controller = try #require(services.windows.controller(for: window))
        let list = controller.sidebar.container.sidebarView.list
        await RapidWorkspaceCreateTests.wait(within: .seconds(30)) { SidebarDocStore.current?.shown != nil }
        try #require(SidebarDocStore.current?.shown != nil, "the same-tree daemon serves the sidebar document")
        func rows(_ layout: SidebarLayout) -> [String] {
            layout.rows.compactMap { if case let .workspace(id) = $0.key { id.rawValue } else { nil } }
        }
        func settled(_ count: Int) -> Bool {
            services.windows.registry.members(of: window).count >= count && PendingWorkspaceRows.shared.rows(in: window).isEmpty
                && rows(list.displayed).count >= count
        }
        // Three loose workspaces, so the end of the list is well below the top.
        let start = services.windows.registry.members(of: window).count
        for count in (start + 1)...(start + 3) {
            _ = services.registry.perform("newTab")
            await RapidWorkspaceCreateTests.wait(within: .seconds(30)) { settled(count) }
        }
        let before = rows(list.displayed)
        try #require(before.count >= 3, "rows before the press: \(before)")
        let home = NewWorkspacePlacements.home(services.machines)
        let top = before.first == home ? 1 : 0

        var frames: [[String]] = []
        list.onApply = { frames.append(rows($0)) }
        _ = services.registry.perform("workspace.newInNewGroup", invocation: ActionInvocation(origin: .script))
        await RapidWorkspaceCreateTests.wait(within: .seconds(30)) { settled(before.count + 1) && rows(list.displayed).count > before.count }
        list.onApply = nil
        let after = rows(list.displayed)
        await launched.stop()

        let created = try #require(after.first { !before.contains($0) }, "the new row: \(after)")
        // At the top: first below Home, or first when its group forms above Home.
        #expect((after.firstIndex(of: created) ?? .max) <= top, "rows \(before) became \(after)")
        let elsewhere = frames.filter { ($0.firstIndex(of: created) ?? 0) > top }
        #expect(elsewhere.isEmpty, "frames that drew the new row away from the top: \(elsewhere)")
    }
}
