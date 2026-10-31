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
    @discardableResult
    static func wait(within limit: Duration, until done: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + limit
        while !done(), ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
        }
        return done()
    }

    /// The app on a fresh same-tree daemon, with the launch window showing its first workspace.
    struct Launched {
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

    /// `sessionEvents`: the connection follows `session.events`, as the app's does (the sidebar document's items and
    /// the personal rows and groups come on it).
    static func launch(sessionEvents: Bool = false, preseedWorkspaceNames: [String] = []) async throws -> Launched {
        let binary = try #require(SameTreeDaemonBinary.url)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cn-race-\(UUID().uuidString.prefix(8))")
        let session = "cn-race-\(UUID().uuidString.prefix(8).lowercased())"
        let launcher = DaemonLauncher(
            configuration: .init(binary: binary, session: session, stateDirectory: root.appendingPathComponent("state")),
            environment: { ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "SHELL": "/bin/sh", "TERM": "xterm-256color"] })
        if !preseedWorkspaceNames.isEmpty {
            let owner = try await launcher.ensure()
            let seed = DaemonConnection(configuration: DaemonConnection.Configuration(terminalEnvironment: nil, sessionEvents: sessionEvents),
                                        endpointProvider: launcher.endpointProvider)
            do {
                _ = try await seed.start()
                for name in preseedWorkspaceNames {
                    _ = try await seed.state.createWorkspace(name: name, ephemeral: false, terminal: true, focus: false)
                }
            } catch {
                // No Launched comes back to stop it: end the daemon `ensure` spawned here, by its pid when the seed
                // connection never learned its identity, and remove the fixture state.
                if let identity = await seed.identity {
                    _ = try? await seed.request(ShutdownDaemonRequest(pid: identity.pid, generation: identity.generation, endTerminals: true),
                                                timeout: .seconds(10))
                } else {
                    kill(owner.pid, SIGTERM)
                }
                await seed.close()
                try? FileManager.default.removeItem(at: root)
                throw error
            }
            await seed.close()
        }
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.palette.bindRegistryActions()
        services.windows.ordersWindowsIn = false
        services.daemon.start {
            DaemonConnection(configuration: DaemonConnection.Configuration(terminalEnvironment: nil, sessionEvents: sessionEvents),
                             endpointProvider: launcher.endpointProvider)
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

    /// Leo 2026-10-18 (nightly 22637785a4): fifty quick Cmd-N presses drew their rows late and out
    /// of order ("workspace-50, 49, 38, 42, 48, 41, 47, 46, 33"; "it goes out of order because it
    /// opens too slowly"). With default names, at key-repeat speed: each press's row is drawn in
    /// the window's sidebar within 250 ms of the press, every drawn frame lists the new rows in
    /// press order, and the names count up with the presses.
    @Test func fiftyCmdNDrawEachRowAtItsPressInPressOrder() async throws {
        let launched = try await Self.launch()
        let services = launched.services
        let window = try #require(services.windows.active?.state.id)
        let controller = try #require(services.windows.controller(for: window))
        let list = controller.sidebar.container.sidebarView.list
        let presses = 50
        let before = Self.rowsBeforePresses(shown: Set(controller.sidebar.model.allWorkspaces.map(\.id.rawValue)),
                                            services: services, window: window)
        /// The new rows the sidebar draws, top to bottom.
        func drawn() -> [String] {
            list.displayed.rows.compactMap { row in
                guard case let .workspace(id) = row.key, !before.contains(id.rawValue) else { return nil }
                return id.rawValue
            }
        }
        var pressed: [ContinuousClock.Instant] = []
        /// Each press's workspace key, in press order (a press adds its row at the press).
        var keys: [String] = []
        var firstDrawn: [String: ContinuousClock.Instant] = [:]
        var misordered: [[Int]] = []
        func sample() {
            for row in PendingWorkspaceRows.shared.rows(in: window) where !keys.contains(row.id) { keys.append(row.id) }
            let now = ContinuousClock.now, rows = drawn()
            for id in rows where firstDrawn[id] == nil { firstDrawn[id] = now }
            let order = rows.compactMap { keys.firstIndex(of: $0) }
            if order != order.sorted(), order != order.sorted(by: >), misordered.count < 5 { misordered.append(order) }
        }

        var work: [ActionWork] = []
        for _ in 1...presses {
            pressed.append(.now)
            work += services.registry.capturingWork { _ = services.registry.perform("newTab") }
            let next = ContinuousClock.now + .milliseconds(33) // key repeat
            while ContinuousClock.now < next { sample(); try? await Task.sleep(for: .milliseconds(3)) }
        }
        var settled = false
        let settleBy = ContinuousClock.now + .seconds(90)
        while !settled, ContinuousClock.now < settleBy {
            sample()
            let members = Set(services.windows.registry.members(of: window))
            settled = keys.count == presses && keys.allSatisfy(members.contains) && PendingWorkspaceRows.shared.rows(in: window).isEmpty
            try? await Task.sleep(for: .milliseconds(5))
        }
        let settle = ContinuousClock.now - pressed[0]
        var failures: [String] = []
        for task in work { if let failure = await task.value { failures.append(failure.message) } }
        let latencies = zip(keys, pressed).map { key, at in firstDrawn[key].map { $0 - at } ?? .seconds(999) }
        let sorted = latencies.sorted()
        let worst = sorted.last ?? .zero
        let numbers = keys.map { key in
            services.daemon.store.workspaces.first { $0.id == key }.flatMap { Int($0.name.dropFirst(SidebarMapping.defaultNamePrefix.count)) } ?? -1
        }
        let final = drawn().compactMap { keys.firstIndex(of: $0) }
        await launched.stop()
        print("fifty-cmd-n: press-to-row median \(sorted.isEmpty ? .zero : sorted[sorted.count / 2]) worst \(worst), settled \(settle) after the first press")

        #expect(keys.count == presses, "\(keys.count) of \(presses) presses added a row")
        #expect(settled, "never settled")
        #expect(worst < .milliseconds(250), "slowest press-to-row \(worst); by press: \(latencies.map { $0.components.seconds * 1000 + $0.components.attoseconds / 1_000_000_000_000_000 })")
        #expect(misordered.isEmpty, "drawn frames out of press order: \(misordered)")
        #expect(final.count == presses && (final == final.sorted() || final == final.sorted(by: >)), "final order by press: \(final)")
        #expect(numbers == numbers.sorted() && Set(numbers).count == presses, "names by press: \(numbers)")
        #expect(failures.isEmpty, "failed: \(failures)")
    }

    /// Lawrence 2026-10-20: "doing Command-N to make a new workspace does not make it the top …
    /// Always make it at the top with a single state change, a single render, and have zero jank"
    /// (plans/cmux-next/sidebar-ordering-DESIGN.md). Over rows already there, one of them unread,
    /// five Cmd-N at key-repeat speed: in every frame the sidebar draws, the new rows are the first
    /// rows below Home, newest first, and the rows that were there keep their order below them (no
    /// new row drawn at the bottom and then moved, none above an old row it then drops below). The
    /// daemon's create places each one, so the app sends no sidebar move of its own.
    @Test func fiveQuickCmdNDrawEachNewRowFirstInEveryFrameAboveUnreadRows() async throws {
        let launched = try await Self.launch()
        let services = launched.services
        // `top` named explicitly (the app's default is afterCurrent since #23014; Lawrence asked for the top).
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
        let store = services.daemon.store
        func settled(_ count: Int) -> Bool {
            PendingWorkspaceRows.shared.rows(in: window).isEmpty && store.workspaces.count >= count
                && !store.workspaces.contains(where: \.isProvisional)
        }
        // Rows to land above: three earlier workspaces, the middle one marked unread.
        let start = store.workspaces.count
        for press in 1...3 {
            _ = services.registry.perform("newTab", invocation: ActionInvocation(arguments: ["name": .string(String(format: "seed-%02d", press))]))
            await Self.wait(within: .seconds(20)) { settled(start + press) }
        }
        let unread = try #require(store.workspaces.first { $0.name == "seed-02" })
        let connection = try #require(services.daemon.connection)
        _ = try await connection.request(SetWorkspaceMetadataRequest(workspace: .handle(unread.handle), markedUnread: true, mutation: connection.mutation()))
        await Self.wait(within: .seconds(10)) {
            controller.sidebar.model.allWorkspaces.first { $0.id.rawValue == unread.id }?.unread.isUnread == true
        }
        let home = NewWorkspacePlacements.home(services.machines)
        let old = controller.sidebar.model.allWorkspaces.map(\.id.rawValue).filter { $0 != home }
        let intentBefore = SidebarDocStore.current?.lastIntentKey

        // Every frame the list draws from the first press until the creates settled.
        var frames: [[String]] = []
        // Per frame, which rows the sidebar document places (d) and which have a personal row (p): says which
        // source a misplaced row came from.
        var sources: [[String: String]] = []
        let personal = services.machines.local.store.personal
        list.onApply = { layout in
            let frame: [String] = layout.rows.compactMap { row in
                guard case let .workspace(id) = row.key, id.rawValue != home else { return nil }
                return id.rawValue
            }
            frames.append(frame)
            let rowed = Set(personal.workspaces.map(\.workspaceKey.rawValue))
            let path = SidebarDocStore.current?.shown == nil ? "personal" : "doc"
            let members = Set(services.windows.registry.members(of: window))
            let pending = Set(PendingWorkspaceRows.shared.rows(in: window).map(\.id))
            let room = services.windows.states[window]?.profileID ?? .defaultProfile
            let docOrder = SidebarDocWiring.sections(of: services.machines.local, room: room, machines: services.machines)?
                .flatMap(\.workspaces).map(\.id).filter { $0 != home }
            sources.append(Dictionary(uniqueKeysWithValues: frame.map { id in
                var tags = path + (SidebarDocWiring.item(workspace: id, services.machines) != nil ? "+d" : "") + (rowed.contains(id) ? "+p" : "")
                tags += members.contains(id) ? "+m" : ""
                tags += pending.contains(id) ? "+pend" : ""
                tags += services.machines.workspace(id: id)?.0.isProvisional == true ? "+prov" : ""
                tags += docOrder.map { "@\($0.firstIndex(of: id).map(String.init) ?? "-")" } ?? "@nil"
                return (id, tags)
            }))
        }
        var keys: [String] = []
        func noteKeys() { for row in PendingWorkspaceRows.shared.rows(in: window) where !keys.contains(row.id) { keys.append(row.id) } }
        var work: [ActionWork] = []
        for press in 1...5 {
            work += services.registry.capturingWork {
                _ = services.registry.perform("newTab", invocation: ActionInvocation(arguments: ["name": .string(String(format: "fresh-%02d", press))]))
            }
            noteKeys()
            let next = ContinuousClock.now + .milliseconds(33) // key repeat
            while ContinuousClock.now < next { noteKeys(); try? await Task.sleep(for: .milliseconds(3)) }
        }
        await Self.wait(within: .seconds(30)) { noteKeys(); return keys.count == 5 && settled(start + 8) }
        // A late reorder (the item's arrival, a placement echo) would draw within this; test-only wait.
        try? await Task.sleep(for: .seconds(1))
        list.onApply = nil
        var failures: [String] = []
        for task in work { if let failure = await task.value { failures.append(failure.message) } }
        let final = controller.sidebar.model.allWorkspaces.map(\.id.rawValue).filter { $0 != home }
        let intentAfter = SidebarDocStore.current?.lastIntentKey
        await launched.stop()

        // Each frame: the new rows it draws come first, newest first; the old rows follow in their order.
        var bad: [[String]] = []
        func label(_ frame: [String]) -> [String] {
            frame.map { id in keys.firstIndex(of: id).map { "new\($0 + 1)" } ?? (id == unread.id ? "unread" : "old") }
        }
        for frame in frames {
            let fresh = frame.filter(keys.contains), rest = frame.filter { !keys.contains($0) }
            let newestFirst = fresh.compactMap { keys.firstIndex(of: $0) }
            let ok = Array(frame.prefix(fresh.count)) == fresh && newestFirst == newestFirst.sorted(by: >)
                && rest == old.filter(rest.contains)
            if !ok, bad.count < 5 { bad.append(label(frame)) }
        }
        // The frame strip (each distinct drawn order, in order) for the before/after gallery.
        var strip: [[String]] = []
        for (frame, source) in zip(frames, sources) {
            let shown = label(frame).enumerated().map { index, name in name.hasPrefix("new") ? "\(name)[\(source[frame[index]] ?? "")]" : name }
            if strip.last != shown { strip.append(shown) }
        }
        print("cmd-n-top settings: app newPlacement \(String(describing: services.settings?.snapshot.newWorkspacePlacement)), "
              + "placesNewRowsFirst \(SidebarDocWiring.docSections.placesNewRowsFirst())")
        print("cmd-n-top frames: \(frames.count) drawn, \(strip.count) distinct: \(strip.map { $0.joined(separator: ",") }.joined(separator: " | "))")
        #expect(keys.count == 5, "\(keys.count) of 5 presses added a row")
        #expect(!frames.isEmpty, "the list drew no frame")
        #expect(bad.isEmpty, "frames with a new row not on top (of \(frames.count)): \(bad)")
        #expect(Array(final.prefix(5)) == Array(keys.reversed()), "final order: \(final), presses: \(keys)")
        #expect(final.dropFirst(5).elementsEqual(old), "old rows moved: \(old) -> \(Array(final.dropFirst(5)))")
        #expect(intentAfter == intentBefore, "the app sent its own sidebar move for a new workspace (a second state change)")
        #expect(failures.isEmpty, "failed: \(failures)")
    }
}
