import AppKit
import CmuxNextActions
import CmuxNextBridge
@testable import CmuxNextApp
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextDesign
@testable import CmuxNextSettings
@testable import CmuxNextSidebar
import Foundation
import Observation
import Testing

/// A workspace switch inside one space changes no row of the sidebar's list: the same workspaces list in the same
/// order, and only the selection moves (the selection has its own pass). So the rows pass of the sidebar
/// (`SidebarBridge.observe`, the pass that lists rows: a walk of every workspace of the space) has no work at such a
/// switch. A sample of 20 switches at 400 workspaces (2026-11-13) showed that pass in 29 samples, each on the pass's
/// own task hop, and in no sample of the same time with no switch: a value the pass reads is written at a switch.
///
/// Each test here counts the rows pass for workspace switches inside one space, on the real daemon with the sidebar
/// document, and names what the switch wrote: each value the pass reads has its own tracking (`terms`), armed before
/// the switch, and the failure message lists the ones that woke.
@MainActor @Suite(.serialized, .timeLimit(.minutes(4)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct WorkspaceSwitchRowsPassTests {
    /// The names of the trackings that a write woke.
    nonisolated final class Woken: @unchecked Sendable {
        private let lock = NSLock()
        private var names: [String] = []
        nonisolated var all: [String] { lock.withLock { names } }
        nonisolated func add(_ name: String) { lock.withLock { names.append(name) } }
    }

    /// The window's shown workspace: every switch writes it, and the rows pass must not read it.
    static let shownTerm = "window: state.workspaceID"

    /// The values of a window's rows pass, one read each. The first 5 are the window's own state (a switch writes
    /// some of them; the pass's own code reads only the space). The others are the reads of the pass
    /// (`SidebarBridge.observe`, `passSections`, `liveSections`), as that code calls them.
    static func terms(_ services: AppServices, _ state: WindowState) -> [(name: String, read: () -> Void)] {
        let machines = services.machines, doc = services.sidebarDoc
        var terms: [(name: String, read: () -> Void)] = []
        terms.append((name: shownTerm, read: { _ = state.workspaceID }))
        terms.append((name: "window: state.page", read: { _ = state.page }))
        terms.append((name: "window: state.cloudCreation", read: { _ = state.cloudCreation }))
        terms.append((name: "window: state.machineID", read: { _ = state.machineID }))
        terms.append((name: "window: state.profileID", read: { _ = state.profileID }))
        terms.append((name: "pass: the window's members (registry.members)", read: { _ = services.windows.registry.members(of: state.id) }))
        terms.append((name: "pass: the sections of the home machine (PersonalSidebar.sections: the sidebar document's sections)", read: {
            _ = PersonalSidebar.sections(of: machines.local, room: state.profileID, machines: machines, doc: doc)
        }))
        terms.append((name: "pass: the document's version (doc.catchingUp)", read: {
            _ = doc.store?.version
            _ = doc.store?.isActive
        }))
        terms.append((name: "pass: the pending rows (PendingWorkspaceRows.listing)", read: {
            _ = PendingWorkspaceRows.shared.listing([], in: state.id, machines: machines, doc: doc)
        }))
        terms.append((name: "pass: the row decorations", read: { _ = services.sidebarCustomization.rowDecorations }))
        terms.append((name: "pass: the space bar (SidebarSpaceBar.profiles)", read: {
            _ = SidebarSpaceBar.profiles(machines.local, window: state.id, windows: services.windows)
        }))
        terms.append((name: "pass: the visible layout (SidebarRows.visibleLayout)", read: { _ = SidebarRows.visibleLayout(services, window: state) }))
        terms.append((name: "pass: the top items (SidebarTopProjection.make)", read: {
            _ = SidebarTopProjection.make(services.sidebarLayout, machines: machines, room: state.profileID.rawValue)
        }))
        terms.append((name: "pass: the muted set, the Home item, the unread setting, the group settings", read: {
            _ = services.notifications.preferences.mutedWorkspaces
            _ = services.sidebarLayout.document.hidesHome
            _ = DesignSettings.shared.attention.showsOnSidebar
            _ = services.settings?.snapshot.workspaceGroups
        }))
        terms.append((name: "pass: the daemon's workspace list (store.workspaces)", read: { _ = services.daemon.store.workspaces.count }))
        // The whole walk with a stub for each row, so no row's own mapping is read. It is WIDER than the pass: the pass
        // keeps each workspace's listing answer and reads its rule only when the answer is stale; this reads each rule,
        // and each workspace's name.
        terms.append((name: "pass, wider: the sections walk with each workspace's listing rule and name (liveSections)", read: {
            _ = SidebarBridge.liveSections(machines, doc: doc, registry: services.windows.registry, window: state,
                                           rows: { workspace, machine, _ in SidebarMapping.unmapped(workspace, machine: machine) })
        }))
        return terms
    }

    /// Arms one tracking for each term; `woken` gets the name of each one that a later write wakes.
    static func arm(_ terms: [(name: String, read: () -> Void)], into woken: Woken) {
        for term in terms {
            let name = term.name
            withObservationTracking(term.read) { woken.add(name) }
        }
    }

    /// One second of real time for the app and the daemon to end the work of a switch (the daemon answers on a socket).
    static func settle() async {
        await RapidWorkspaceCreateTests.wait(within: .seconds(1)) { false }
    }

    static func rowsPasses(reset: Bool) -> Int { SidebarView.perfCounters(reset: reset)["rebuilds"] ?? 0 }

    /// Three workspaces with a terminal each, in one window and one space, on the real daemon; then 6 switches among
    /// them, each shown before (so no content is built in a counted switch).
    static func countSwitches(_ launched: RapidWorkspaceCreateTests.Launched, names: [String], belowCurrent: Bool) async throws {
        let services = launched.services
        let window = try #require(services.windows.active?.state.id)
        let controller = try #require(services.windows.controller(for: window))
        let state = controller.state
        let store = services.daemon.store
        if belowCurrent {
            let config = launched.root.appendingPathComponent("cmux.json")
            try Data(#"{"workspaces":{"newPlacement":"afterCurrent"}}"#.utf8).write(to: config)
            let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: config,
                                              managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
            await settings.reload()
            services.settings = settings
            try #require(services.settings?.snapshot.newWorkspacePlacement == .afterCurrent)
        }
        await RapidWorkspaceCreateTests.wait(within: .seconds(30)) { services.sidebarDoc.store?.shown != nil }
        try #require(services.sidebarDoc.store?.shown != nil, "the same-tree daemon serves the sidebar document")
        await RapidWorkspaceCreateTests.wait(within: .seconds(30)) {
            names.allSatisfy { name in store.workspaces.contains { $0.name == name && !$0.isProvisional } }
        }
        let ids = names.compactMap { name in store.workspaces.first { $0.name == name && !$0.isProvisional }?.id }
        try #require(ids.count == names.count, "the workspaces made before the launch: \(store.workspaces.map(\.name))")
        for id in ids { services.windows.claim(workspaceID: id, in: state, select: false) }
        await RapidWorkspaceCreateTests.wait(within: .seconds(30)) {
            ids.allSatisfy { services.windows.registry.value.owner(of: $0) == window }
        }
        try #require(ids.allSatisfy { services.windows.registry.value.owner(of: $0) == window }, "the window does not own the 3 workspaces")
        // Each one shown once: its content is built and stays mounted.
        for id in ids {
            services.windows.show(workspaceID: id, in: state, from: .thisWindow)
            await settle()
            try #require(state.workspaceID == id, "the window shows \(state.workspaceID ?? "nothing"), not \(id)")
        }
        // The pass computes with the settings of this test, whatever it read before.
        controller.sidebar.sameTurn.syncNow(rows: true)
        // No switch: the rows pass must be still, else a count of it proves nothing.
        var quiet = false
        for _ in 0..<20 where !quiet {
            _ = rowsPasses(reset: true)
            await settle()
            quiet = rowsPasses(reset: true) == 0
        }
        try #require(quiet, "the rows pass runs with no switch: a count of it for a switch proves nothing")
        let terms = Self.terms(services, state)
        let label = belowCurrent ? "afterCurrent" : "default"
        // The same time with no switch: what wakes here is not a switch's.
        let still = Woken()
        arm(terms, into: still)
        await settle()
        print("WORKSPACE-SWITCH-ROWS-PASS placement=\(label) no_switch rows_passes=\(rowsPasses(reset: true)) woke=\(still.all)")

        for round in 0..<6 {
            let target = ids[round % ids.count]
            try #require(state.workspaceID != target, "switch \(round) has no other workspace to show")
            let woken = Woken()
            arm(terms, into: woken)
            _ = rowsPasses(reset: true)
            let wakes = ObservationWakes()
            ObservationWakes.$current.withValue(wakes) { services.windows.show(workspaceID: target, in: state, from: .thisWindow) }
            let inTurn = rowsPasses(reset: false)
            let wokeInTurn = woken.all
            await settle()
            let passes = rowsPasses(reset: true)
            let woke = woken.all
            let sites = wakes.bySite.filter { $0.key.contains("Sidebar") }.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
            print("WORKSPACE-SWITCH-ROWS-PASS placement=\(label) switch=\(round) rows_passes=\(passes) in_turn=\(inTurn) "
                + "woke_in_turn=\(wokeInTurn) woke=\(woke) sites_in_turn=\(sites)")
            try #require(state.workspaceID == target, "switch \(round): the window shows \(state.workspaceID ?? "nothing"), not \(target)")
            try #require(woke.contains(shownTerm), "switch \(round): the tracking of state.workspaceID did not wake: the trackings of this test prove nothing")
            #expect(passes == 0, """
                switch \(round) (\(label)): the rows pass ran \(passes) time(s) for a workspace switch inside one space (\(inTurn) in the turn \
                of the switch). The switch wrote these values (in its turn: \(wokeInTurn)): \(woke). The sidebar trackings woken in its turn: \(sites)
                """)
        }
    }

    static func run(belowCurrent: Bool) async throws {
        let names = (1...3).map { "rows-pass-\($0)" }
        let launched = try await RapidWorkspaceCreateTests.launch(sessionEvents: true, preseedWorkspaceNames: names)
        do {
            try await countSwitches(launched, names: names, belowCurrent: belowCurrent)
        } catch {
            await launched.stop()
            throw error
        }
        await launched.stop()
    }

    /// The default settings (`workspaces.newPlacement` = `top`), as the sample had.
    @Test func aWorkspaceSwitchInsideOneSpaceRunsNoRowsPass() async throws {
        try await Self.run(belowCurrent: false)
    }

    /// `workspaces.newPlacement` = `afterCurrent`: the place of a new workspace's row is "below the window's current
    /// workspace", and the sections of the sidebar document ask for that place at each compute
    /// (`SidebarDocSections.sections`), so the rows pass reads the window's shown workspace and each switch runs it.
    @Test func aWorkspaceSwitchRunsNoRowsPassWhenNewRowsGoBelowTheCurrentWorkspace() async throws {
        try await Self.run(belowCurrent: true)
    }
}
