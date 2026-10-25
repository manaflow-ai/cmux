import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextDesign
@testable import CmuxNextSettings
@testable import CmuxNextSidebar
import Foundation
import Testing

/// Austin 2026-10-20: Cmd-N "draws the new workspace somewhere in the sidebar and then moves it via an
/// animation / glitch to the right place". On the sidebar document (`sidebar-doc-v1`) the daemon's
/// workspace replaced Cmd-N's pending row in the turn it took over the stand-in, while the document's
/// projection (rebuilt a hop later) did not place it yet: the row drew after every placed row, then
/// sprang to its slot. Every layout the list applies must show the new row only at its slot.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct CmdNRowSlotTests {
    @Test func cmdNDrawsTheNewRowOnlyAtItsSlot() async throws {
        let launched = try await RapidWorkspaceCreateTests.launch()
        let services = launched.services
        // The slot named explicitly, so the base's default (`top`) does not decide the result: only the jump does.
        let url = launched.root.appendingPathComponent("cmux.json")
        try Data(#"{"workspaces":{"newPlacement":"afterCurrent"}}"#.utf8).write(to: url)
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        await settings.reload()
        services.settings = settings
        try #require(services.settings?.snapshot.newWorkspacePlacement == .afterCurrent)
        let window = try #require(services.windows.active?.state.id)
        let controller = try #require(services.windows.controller(for: window))
        let state = controller.state
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
        func describe() -> String {
            "members \(services.windows.registry.members(of: window).count), pending \(PendingWorkspaceRows.shared.rows(in: window).count), drawn \(rows(list.displayed))"
        }
        // Three more workspaces, so the row below the anchor is not the end of the list.
        let start = services.windows.registry.members(of: window).count
        for count in (start + 1)...(start + 3) {
            _ = services.registry.perform("newTab")
            await RapidWorkspaceCreateTests.wait(within: .seconds(30)) { settled(count) }
            if !settled(count) { print("cmd-n-slot: not settled at \(count): \(describe())") }
        }
        let before = rows(list.displayed)
        // Two rows above the last: the daemon's own place (the end) is two rows below the slot.
        let at = before.count - 3
        guard at >= 0 else { await launched.stop(); Issue.record("rows before the press: \(before)"); return }
        let anchor = before[at]
        services.windows.select(anchor, in: state)
        controller.showWorkspace(requested: state.workspaceID)

        var frames: [[String]] = []
        list.onApply = { frames.append(rows($0)) }
        _ = services.registry.perform("newTab")
        await RapidWorkspaceCreateTests.wait(within: .seconds(30)) { settled(start + 4) && rows(list.displayed).count > before.count }
        if !settled(start + 4) { print("cmd-n-slot: not settled after the press: \(describe())") }
        list.onApply = nil
        let after = rows(list.displayed)
        await launched.stop()

        let created = try #require(after.first { !before.contains($0) }, "the new row: \(after)")
        #expect(after == Array(before[...at]) + [created] + before[(at + 1)...], "rows \(before) became \(after)")
        let elsewhere = frames.filter { frame in frame.contains(created) && frame.firstIndex(of: created) != frame.firstIndex(of: anchor).map { $0 + 1 } }
        #expect(elsewhere.isEmpty, "frames that drew the new row away from its slot below \(anchor): \(elsewhere)")
    }
}
