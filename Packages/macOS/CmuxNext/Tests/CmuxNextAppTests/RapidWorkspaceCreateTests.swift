import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextSidebar
import Foundation
import Testing

/// Cmd-N at key-repeat speed with Close Workspace pressed in between, on the real daemon and the
/// app's launch window (cx-7cit9, Leo: "rapid Cmd-N outraces creation, workspaces 3-6 missing
/// from the sidebar, and deleting during that shows a raw `no workspace <id>` toast").
/// - every workspace asked for and not closed is in the window's sidebar, in press order;
/// - each close takes exactly one workspace, and a closed one never comes back;
/// - no press fails, and no notice names a raw id.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct RapidWorkspaceCreateTests {
    private static let presses = 20
    /// Close Workspace is pressed right after these presses.
    private static let closesAfter: Set<Int> = [5, 6, 12, 18]

    @MainActor private final class Notices {
        var shown: [String] = []
    }

    private static func name(_ press: Int) -> String { String(format: "race-%02d", press) }

    /// Polls until `done` holds or `limit` passes (a poll, as in `FirstLaunchTests`).
    private static func wait(within limit: Duration, until done: () -> Bool) async {
        let deadline = ContinuousClock.now + limit
        while !done(), ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// The app on a fresh same-tree daemon, with the launch window showing its first workspace.
    private struct Launched {
        let services: AppServices
        let root: URL

        /// Ends the daemon (and its terminals), closes the windows and removes the state.
        func stop() async {
            if let connection = services.daemon.connection, let identity = services.daemon.identity {
                _ = try? await connection.request(ShutdownDaemonRequest(pid: identity.pid, generation: identity.generation, endTerminals: true),
                                                  timeout: .seconds(10))
            }
            services.daemon.shutdownConnection()
            for controller in services.windows.controllers { controller.window?.close() }
            try? FileManager.default.removeItem(at: root)
        }
    }

    private static func launch() async throws -> Launched {
        let binary = try #require(SameTreeDaemonBinary.url)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cn-race-\(UUID().uuidString.prefix(8))")
        let session = "cn-race-\(UUID().uuidString.prefix(8).lowercased())"
        let launcher = DaemonLauncher(
            configuration: .init(binary: binary, session: session, stateDirectory: root.appendingPathComponent("state")),
            environment: { ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "SHELL": "/bin/sh", "TERM": "xterm-256color"] })
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.palette.bindRegistryActions()
        services.windows.ordersWindowsIn = false
        services.daemon.start {
            DaemonConnection(configuration: DaemonConnection.Configuration(terminalEnvironment: nil), endpointProvider: launcher.endpointProvider)
        }
        services.windows.restoreWhenLoaded()
        await Self.wait(within: .seconds(90)) {
            services.windows.active.flatMap { services.windows.registry.members(of: $0.state.id).first } != nil
        }
        return Launched(services: services, root: root)
    }

    /// The rows a count of new rows leaves out: those `shown` in the window's sidebar before the
    /// presses, and every workspace the window or the daemon had by then, which the sidebar may not
    /// show yet (it follows the registry and the store a main-actor hop later).
    private static func rowsBeforePresses(shown: Set<String>, services: AppServices, window: String) -> Set<String> {
        shown.union(services.windows.registry.members(of: window)).union(services.daemon.store.workspaces.map(\.id))
    }

    /// `launch()` returns once the window registry lists the launch workspace, but the sidebar
    /// shows it after that (its rows come from an observation that runs a main-actor hop later),
    /// so the rows shown before the presses can still lack it. The new rows the presses are
    /// counted against must leave it out anyway (feat-cmux-next 4c55c90cf329: "11 rows" for 10).
    @Test func rowsBeforeThePressesLeaveTheLaunchWorkspaceOutWhenTheSidebarLags() async throws {
        let launched = try await Self.launch()
        let services = launched.services
        let window = try #require(services.windows.active?.state.id)
        let sidebar = try #require(services.windows.controller(for: window)?.sidebar.model)
        let owned = Set(services.windows.registry.members(of: window))
        // The sidebar before its observation showed the launch workspace: no rows yet.
        let before = Self.rowsBeforePresses(shown: [], services: services, window: window)
        func live() -> [String] { sidebar.allWorkspaces.filter { $0.rowState == .live }.map(\.id.rawValue) }
        await Self.wait(within: .seconds(30)) { !owned.isDisjoint(with: live()) }
        let shown = live()
        await launched.stop()

        #expect(!owned.isDisjoint(with: shown), "the sidebar never showed the launch workspace: \(owned) vs \(shown)")
        #expect(shown.filter { !before.contains($0) }.isEmpty, "counted as new: \(shown.filter { !before.contains($0) })")
    }

    @Test func twentyCmdNWithClosesInBetweenKeepEveryWorkspaceInPressOrder() async throws {
        let launched = try await Self.launch()
        let services = launched.services
        let store = services.daemon.store
        let window = try #require(services.windows.active?.state.id)
        let before = Set(store.workspaces.map(\.id))
        // The notices a keyboard run shows (a quiet refusal shows none).
        let notices = Notices()
        let shows = services.registry.refusalObserver
        services.registry.refusalObserver = { reason, quiet in
            if !quiet { notices.shown.append(reason) }
            shows?(reason, quiet)
        }

        // 20 presses at key-repeat speed, each named so its sidebar row says which press made it,
        // with Close Workspace pressed between some of them. `pressing` is the time the presses
        // themselves hold the main actor (no press waits for its create); the 30 ms gaps are left
        // out, since a busy test host oversleeps them (1.7-2.6 s for 20 on the fleet).
        var work: [ActionWork] = []
        var pressing = Duration.zero
        for press in 1...Self.presses {
            let pressed = ContinuousClock.now
            work += services.registry.capturingWork {
                _ = services.registry.perform("newTab", invocation: ActionInvocation(arguments: ["name": .string(Self.name(press))]))
            }
            if Self.closesAfter.contains(press) {
                work += services.registry.capturingWork { _ = services.registry.perform("closeWorkspace") }
            }
            pressing += ContinuousClock.now - pressed
            try? await Task.sleep(for: .milliseconds(30))
        }
        var failures: [String] = []
        for task in work { if let failure = await task.value { failures.append(failure.message) } }

        // Settled: nothing in flight, and the store and the window agree.
        let expected = before.count + Self.presses - Self.closesAfter.count
        await Self.wait(within: .seconds(30)) {
            store.workspaces.count == expected && Set(services.windows.registry.members(of: window)) == Set(store.workspaces.map(\.id))
        }
        // A closed workspace that would come back (a create that finished after its close) shows
        // within this; test-only wait.
        try? await Task.sleep(for: .seconds(2))

        let members = Set(services.windows.registry.members(of: window))
        let created = store.workspaces.filter { !before.contains($0.id) }
        let order = WindowManager.orderedIDs(of: services.daemon, machines: services.machines).filter(members.contains)
        let presses = order.compactMap { id in created.first { $0.id == id }?.name }.compactMap { name in
            (1...Self.presses).first { Self.name($0) == name }
        }
        let ids = before.union(created.map(\.id))
        let refusals = notices.shown

        await launched.stop()

        #expect(pressing < .seconds(1), "the presses held the main actor for \(pressing)")
        // Each close took exactly one workspace; none of the others is missing.
        #expect(store.workspaces.count == expected)
        #expect(created.allSatisfy { members.contains($0.id) }, "not in the sidebar: \(created.filter { !members.contains($0.id) }.map(\.name))")
        #expect(presses.count == created.count, "unnamed or duplicate workspaces: \(created.map(\.name))")
        // Press order: each new workspace lands at the same end (top or bottom, by the setting).
        #expect(presses == presses.sorted() || presses == presses.sorted(by: >), "sidebar order by press: \(presses)")
        #expect(failures.isEmpty, "failed: \(failures)")
        #expect(refusals.isEmpty, "notices: \(refusals)")
        #expect(!(failures + refusals).contains { message in ids.contains { message.contains($0) } })
    }

    /// cx-9a7wx: each Cmd-N shows its row at the press, before the daemon has made the workspace
    /// (rapid presses wait their turn, so the last one used to show seconds later). The row is
    /// the workspace's own: once the daemon reports it, the same row, in the same place, shows it,
    /// and no row leaves the sidebar on the way.
    @Test func cmdNShowsItsRowAtThePressAndTheWorkspaceTakesIt() async throws {
        let launched = try await Self.launch()
        let services = launched.services
        let window = try #require(services.windows.active?.state.id)
        let sidebar = try #require(services.windows.controller(for: window)?.sidebar.model)
        let presses = 10
        let before = Self.rowsBeforePresses(shown: Set(sidebar.allWorkspaces.map(\.id.rawValue)), services: services, window: window)
        /// The new rows, top to bottom.
        func rows() -> [String] { sidebar.allWorkspaces.map(\.id.rawValue).filter { !before.contains($0) } }

        var work: [ActionWork] = []
        let started = ContinuousClock.now
        for press in 1...presses {
            work += services.registry.capturingWork {
                _ = services.registry.perform("newTab", invocation: ActionInvocation(arguments: ["name": .string(String(format: "row-%02d", press))]))
            }
            await Task.yield()
        }
        let deadline = started + .milliseconds(250)
        while rows().count < presses, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        let atPress = rows()
        let shownAfter = ContinuousClock.now - started

        // Until every create finished and the window lists it, no row leaves the sidebar.
        var gaps: Set<String> = []
        var settled = false
        let settleBy = ContinuousClock.now + .seconds(30)
        while !settled, ContinuousClock.now < settleBy {
            let shown = Set(rows())
            gaps.formUnion(atPress.filter { !shown.contains($0) })
            let members = Set(services.windows.registry.members(of: window))
            settled = atPress.count == presses && atPress.allSatisfy(members.contains)
                && sidebar.allWorkspaces.filter { atPress.contains($0.id.rawValue) }.allSatisfy { $0.rowState == .live }
            try? await Task.sleep(for: .milliseconds(10))
        }
        var failures: [String] = []
        for task in work { if let failure = await task.value { failures.append(failure.message) } }
        let final = rows()
        let names = final.compactMap { id in services.daemon.store.workspaces.first { $0.id == id }?.name }
        await launched.stop()

        #expect(atPress.count == presses, "\(atPress.count) rows \(shownAfter) after the first press")
        #expect(settled, "never settled: \(final)")
        // The same rows, in the same order, now the workspaces' own.
        #expect(final == atPress, "rows changed: \(atPress) -> \(final)")
        #expect(names.count == presses && (names == names.sorted() || names == names.sorted(by: >)), "press order: \(names)")
        #expect(gaps.isEmpty, "rows left the sidebar: \(gaps)")
        #expect(failures.isEmpty, "failed: \(failures)")
    }

    /// Lawrence 2026-10-18 (NIGHTLY): with a group first in the list, a Cmd-N row drew at its
    /// `workspaces.newPlacement` slot (above the group), then jumped below the group once the
    /// daemon reported the workspace: on the sidebar document the placement went to the personal
    /// order, which the document does not show, and the daemon's sync from that order put it
    /// after the group. The row stays where it drew at the press, in every sample, until well
    /// after it is the workspace's own.
    @Test func cmdNRowStaysWhereItDrewAtThePressBesideAGroup() async throws {
        let launched = try await Self.launch()
        let services = launched.services
        let state = try #require(services.windows.active?.state)
        let window = state.id
        let bridge = try #require(services.windows.controller(for: window)?.sidebar)
        let sidebar = bridge.model
        let notices = Notices()
        let shows = services.registry.refusalObserver
        services.registry.refusalObserver = { reason, quiet in
            notices.shown.append(reason)
            shows?(reason, quiet)
        }
        // The report's path: the sidebar document orders the rows (the older paths held the row by a pending edit).
        await Self.wait(within: .seconds(30)) { SidebarDocWiring.isActive }
        try #require(SidebarDocWiring.isActive, "the same-tree daemon serves no sidebar document")
        func live(_ id: String) -> Bool { sidebar.allWorkspaces.contains { $0.id.rawValue == id && $0.rowState == .live } }
        func layout() -> String {
            sidebar.sections.flatMap(\.nodes).map { node in
                if case let .group(group) = node { return "[\(group.name): \(group.workspaces.map(\.title).joined(separator: ", "))]" }
                return node.workspaces.map(\.title).joined(separator: ", ")
            }.joined(separator: " | ")
        }
        // The list as in the report: a group first, the shown workspace loose after it.
        let loose = try #require(services.windows.registry.members(of: window).first)
        await Self.wait(within: .seconds(30)) { live(loose) }
        let seed = services.registry.capturingWork {
            _ = services.registry.perform("newTab", invocation: ActionInvocation(arguments: ["name": .string("grouped")]))
        }
        await Self.wait(within: .seconds(30)) { sidebar.allWorkspaces.contains { $0.title == "grouped" && $0.rowState == .live } }
        let grouped = try #require(sidebar.allWorkspaces.first { $0.title == "grouped" }?.id.rawValue)
        await Self.wait(within: .seconds(10)) { state.workspaceID == grouped }
        // One document change, as a group made in the sidebar sends: the group, first in the list.
        let doc = try #require(SidebarDocStore.current)
        await Self.wait(within: .seconds(30)) {
            SidebarDocWiring.item(workspace: grouped, services.machines).map { doc.records.items[$0] != nil } ?? false
        }
        let item = try #require(SidebarDocWiring.item(workspace: grouped, services.machines))
        let section = try #require(doc.records.items[item]?.section)
        try doc.sendChecked(ops: [["op": "group.create", "id": GroupID.make().rawValue, "name": "Accounts", "color": "grey",
                                   "items": [item], "to": ["section": section, "index": 0]]], title: "Group", undoable: false)
        func groupFirst() -> Bool {
            guard case let .group(first)? = sidebar.sections.first(where: { !$0.nodes.isEmpty && $0.machine != nil })?.nodes.first else { return false }
            return first.name == "Accounts" && first.workspaces.map(\.id.rawValue) == [grouped]
        }
        await Self.wait(within: .seconds(30)) { groupFirst() }
        services.windows.select(loose, in: state)
        await Self.wait(within: .seconds(10)) { state.workspaceID == loose }
        var seedFailures: [String] = []
        for task in seed { if let failure = await task.value { seedFailures.append(failure.message) } }
        let ready = groupFirst() && state.workspaceID == loose
        let before = Set(sidebar.allWorkspaces.map(\.id.rawValue))
        let start = layout()

        let work = services.registry.capturingWork {
            _ = services.registry.perform("newTab", invocation: ActionInvocation(arguments: ["name": .string("slot-01")]))
        }
        // Each place the new row takes (how many of the rows listed before the press are above it), in order: one place is no jump.
        var added: String?
        var places: [Int] = []
        var settledAt: ContinuousClock.Instant?
        let giveUp = ContinuousClock.now + .seconds(30)
        // Samples until 2 s after the row is the listed workspace's own (late echoes land in that time).
        while ContinuousClock.now < (settledAt.map { $0 + .seconds(2) } ?? giveUp) {
            let shown = sidebar.allWorkspaces
            if added == nil { added = shown.first { !before.contains($0.id.rawValue) }?.id.rawValue }
            if let added, let index = shown.firstIndex(where: { $0.id.rawValue == added }) {
                let above = shown[..<index].filter { before.contains($0.id.rawValue) }.count
                if places.last != above { places.append(above) }
            }
            if settledAt == nil, let added, services.windows.registry.members(of: window).contains(added), live(added) {
                settledAt = .now
            }
            try? await Task.sleep(for: .milliseconds(2))
        }
        var failures: [String] = []
        for task in work { if let failure = await task.value { failures.append(failure.message) } }
        let end = layout()
        print("cmdN-beside-group: places=\(places) before: \(start) after: \(end) notices: \(notices.shown)")
        await launched.stop()

        #expect(ready, "setup: no group first with the shown workspace loose after it: \(start) \(seedFailures) \(notices.shown)")
        #expect(added != nil, "no new row")
        #expect(settledAt != nil, "never the workspace's own row: \(end)")
        #expect(places.count == 1, "the new row moved through \(places) rows above it: \(start) -> \(end)")
        #expect(failures.isEmpty, "failed: \(failures)")
    }
}
