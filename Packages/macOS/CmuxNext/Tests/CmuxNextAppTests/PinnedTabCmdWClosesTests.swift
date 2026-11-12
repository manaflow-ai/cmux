import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextDesign
@testable import CmuxNextSettings
import CmuxNextTabs
import Foundation
import Testing

/// Lawrence 2026-11-08 (cmux-ad i8): "Cmd-W on a pinned tab selects the tab before. make it
/// consistent, match chrome's behavior".
///
/// Cmd-W closes a pinned tab as it closes any tab, as Chrome's does: there is no kept pinned tab.
/// The close then selects by the one close rule (`FocusAfterClose.tab`): the tab before, only the
/// first tab the tab after. Before, Cmd-W on a pinned tab could keep it and select the NEXT tab
/// (`tabs.cmdWClosesPinnedTabs` off); a config that still has that key closes the pinned tab too.
/// Each case runs the app's own action (or the CLI's close) against a same-tree cmux-tui daemon.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct PinnedTabCmdWClosesTests {
    /// One pane: its terminal tab, then five browser tabs; the first three tabs pinned
    /// (P0 P1 P2 | U3 U4 U5). Returns the pane, the ids in strip order and each id's surface.
    private static func pane(_ services: AppServices, _ connection: DaemonConnection) async throws -> (PaneController, [String], [String: SurfaceID]) {
        let store = services.daemon.store
        let content = try #require(services.windows.active?.workspaceContent)
        let model = try #require(store.workspaces.first?.screens.first?.panes.first)
        let pane = try #require(services.paneController(for: model))
        var surfaces: [SurfaceID] = [try #require(model.tabs.first).surface]
        for index in 0..<5 {
            let tab = try await connection.newFrontendBrowserTab(url: "https://example.com/\(index)", engine: .webkit,
                                                                 in: model.handle, activate: false)
            surfaces.append(tab.surface)
        }
        try await PinnedPageTests.until({ surfaces.allSatisfy { store.tab(surface: $0) != nil } })
        var ids: [String] = []
        var surfaceOf: [String: SurfaceID] = [:]
        for surface in surfaces {
            let id = try #require(store.tab(surface: surface)).id
            ids.append(id)
            surfaceOf[id] = surface
        }
        for id in ids.prefix(3) { _ = try await connection.setTabPinned(try #require(surfaceOf[id]), true) }
        try await PinnedPageTests.until({ pane.orderedIDs.map(\.rawValue) == ids && pane.stripModel.orderedTabs.prefix(3).allSatisfy(\.isPinned) },
                                        report: { "the pane holds \(pane.orderedIDs.map(\.rawValue)), wanted \(ids) with the first three pinned" })
        PaneHandlers.focus(pane.layoutPaneID, in: content)
        return (pane, ids, surfaceOf)
    }

    /// A settings file with the old opt-out a user's config may still have (`tabs.cmdWClosesPinnedTabs: false`).
    private static func installOldOptOut(_ services: AppServices) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cn-pinned-cmdw-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "cmux.json")
        try Data(#"{"tabs": {"cmdWClosesPinnedTabs": false}}"#.utf8).write(to: url)
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        services.settings = settings
        await settings.reload()
    }

    private static func select(_ id: String, in pane: PaneController) async throws {
        pane.select(TabID(id))
        try await PinnedPageTests.until({ pane.stripModel.selectedID?.rawValue == id })
    }

    /// Waits until `closed` is gone and `pane` selects `selected`.
    private static func expect(_ pane: PaneController, _ services: AppServices, closed: String, selects selected: String,
                               _ what: String, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let store = services.daemon.store
        try await PinnedPageTests.until({ store.tab(id: closed) == nil && pane.stripModel.selectedID?.rawValue == selected },
                                        report: { "\(what): the pane holds \(pane.orderedIDs.map(\.rawValue)), selects \(pane.stripModel.selectedID?.rawValue ?? "none"), wanted \(closed) closed and \(selected) selected" },
                                        sourceLocation: sourceLocation)
    }

    private static func cmdW(_ services: AppServices) -> Bool {
        services.registry.perform("closeTab", invocation: ActionInvocation(origin: .user))
    }

    /// Cmd-W on pinned P1 closes it and selects pinned P0 (the tab before); Cmd-W on P0 (now the
    /// first tab) closes it and selects P2 (the tab after). The old opt-out key changes nothing.
    @Test func cmdWClosesAPinnedTabAndSelectsTheTabBefore() async throws {
        try await PinnedPageTests.withApp { services, connection in
            try await Self.installOldOptOut(services)
            let (pane, ids, _) = try await Self.pane(services, connection) // P0 P1 P2 | U3 U4 U5
            try await Self.select(ids[1], in: pane)
            #expect(Self.cmdW(services))
            try await Self.expect(pane, services, closed: ids[1], selects: ids[0], "Cmd-W on pinned P1")
            #expect(Self.cmdW(services))
            try await Self.expect(pane, services, closed: ids[0], selects: ids[2], "Cmd-W on pinned P0, the first tab")
            #expect(pane.stripModel.orderedTabs.map(\.id.rawValue) == Array(ids[2...]))
        }
    }

    /// The CLI's close of a selected pinned tab selects the tab before it too (P2: pinned P1), and
    /// Cmd-W on the last pinned tab selects the pinned tab before it, not the first unpinned tab.
    @Test func theCLICloseAndTheLastPinnedTabSelectTheTabBefore() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let (pane, ids, surface) = try await Self.pane(services, connection) // P0 P1 P2 | U3 U4 U5
            try await Self.select(ids[2], in: pane)
            try await connection.closeTab(try #require(surface[ids[2]]))
            try await Self.expect(pane, services, closed: ids[2], selects: ids[1], "the CLI's close of pinned P2")
            #expect(Self.cmdW(services))
            try await Self.expect(pane, services, closed: ids[1], selects: ids[0], "Cmd-W on the last pinned tab P1")
        }
    }
}
