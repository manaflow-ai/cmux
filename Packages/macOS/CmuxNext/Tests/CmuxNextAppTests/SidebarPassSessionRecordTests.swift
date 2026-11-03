import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import Foundation
import Observation
import Testing

/// Idle CPU with agents running (Leo 2026-11-03: "im at 100% cpu rn"). A 2 s sample of the nightly spent about 20 % of
/// the main thread in the sidebar's rows pass (`SidebarBridge.liveSections` -> `PersonalSidebar.mixedSections`, a sort
/// of every personal row), woken by `list-personal` refetches whose only change was a session record
/// (`PersonalStore.sessions` setter). The pass read the whole record list for the machine headers' icons, so any record
/// field moving (`last_seen_ms`, a name) ran the full pass in every window. The pass now observes only the records'
/// icon fields (`PersonalStore.sessionIcons`), and reads the personal order sorted once per change of the rows.
///
/// The store holds 200 workspaces of this Mac and 50 session records with 40 personal rows each (2,000 rows); one
/// update is a `list-personal` applied as the refetch applies it, and 20 updates are one second of a 20 Hz stream.
@MainActor @Suite(.serialized) struct SidebarPassSessionRecordTests {
    static let session = "s-local"
    static let workspaceCount = 200
    static let sessionCount = 50
    static let rowsPerOtherSession = 40
    static let updates = 20

    static func records(seen: UInt64, icon: String? = nil) -> [SessionRecord] {
        (0..<sessionCount).map { index in
            let id = index == 0 ? session : "s-\(index)"
            return SessionRecord(id: id, machineName: "Machine \(index)", sessionName: id,
                                 transport: index == 0 ? .object(["kind": .string("local")]) : .object(["kind": .string("cloud"), "machine": .string("m\(index)")]),
                                 lastSeenMs: seen + UInt64(index), capabilities: ["profiles-v1"], migrated: true, icon: index == 0 ? icon : nil)
        }
    }

    /// This Mac's rows, interleaved with the other sessions' rows so the personal order is a real sort.
    static func personalRows(reversed: Bool = false) -> [PersonalWorkspace] {
        var rows: [PersonalWorkspace] = []
        let local = (0..<workspaceCount).map { "k\($0)" }
        for (index, key) in (reversed ? local.reversed() : local).enumerated() {
            rows.append(PersonalWorkspace(sessionID: session, workspaceKey: WorkspaceKey(rawValue: key), index: index * 11))
        }
        for other in 1..<sessionCount {
            for row in 0..<rowsPerOtherSession {
                rows.append(PersonalWorkspace(sessionID: "s-\(other)", workspaceKey: WorkspaceKey(rawValue: "r\(row)"),
                                              index: (other * rowsPerOtherSession + row) * 7 % 5_003))
            }
        }
        return rows
    }

    static func personal(revision: UInt64, seen: UInt64, icon: String? = nil, reversed: Bool = false) -> PersonalState {
        PersonalState(revision: revision, sessions: records(seen: seen, icon: icon), workspaces: personalRows(reversed: reversed))
    }

    @MainActor final class Fixture {
        let services: AppServices
        let state: WindowState
        private(set) var passes = 0
        private(set) var passTime: Duration = .zero
        private var woke = false

        init() throws {
            _ = NSApplication.shared
            services = AppServices(environment: AppEnvironment.current([:]))
            let store = services.machines.local.store
            let json = #"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1","capabilities":["profiles-v1","personal-mixed-order-v1"]}"#
            let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8))
            store.noteHandshake(identity)
            store.connectionState = .connected(identity)
            var tree = DaemonTree(registryID: session, workspaces: (0..<workspaceCount).map { index in
                WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64(index + 1)), key: WorkspaceKey(rawValue: "k\(index)"), name: "Workspace \(index)")
            })
            tree.personal = SidebarPassSessionRecordTests.personal(revision: 1, seen: 1_000)
            store.apply(snapshot: tree)
            let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"pass-records","workspace_key":"pass-records-home"}"#.utf8))
            state = WindowState(record: record)
            services.windows.registry.provisional[state.id] = (0..<workspaceCount).map { "k\($0)" }
            arm()
        }

        /// The window's rows pass under observation tracking, as `SidebarSameTurn` runs it: a change to anything it
        /// read wakes it once.
        func arm() {
            woke = false
            let start = ContinuousClock.now
            withObservationTracking {
                _ = SidebarBridge.liveSections(services.machines, doc: services.sidebarDoc, registry: services.windows.registry, window: state)
            } onChange: { [weak self] in
                MainActor.assumeIsolated { self?.woke = true }
            }
            passTime += ContinuousClock.now - start
        }

        /// Applies `state` as the `list-personal` refetch does; runs the pass again when it woke.
        func refetch(_ state: PersonalState) {
            services.machines.local.store.applyPersonal(state)
            guard woke else { return }
            passes += 1
            arm()
        }

        func reset() {
            passes = 0
            passTime = .zero
        }

        /// Main-thread milliseconds the passes took since the last reset.
        var passMilliseconds: Double {
            Double(passTime.components.seconds) * 1_000 + Double(passTime.components.attoseconds) / 1e15
        }
    }

    /// RED at base: each record update woke the whole pass (20 of 20). GREEN: none do.
    @Test func sessionRecordUpdatesDoNotRunTheSidebarPass() throws {
        let fixture = try Fixture()
        fixture.reset()
        for update in 1...Self.updates {
            fixture.refetch(Self.personal(revision: UInt64(1 + update), seen: 1_000 + UInt64(update) * 50))
        }
        let passes = fixture.passes, ms = fixture.passMilliseconds
        // One pass alone, for the table: the same pass the window runs, timed over 10 runs.
        fixture.reset()
        for _ in 0..<10 { fixture.arm() }
        let onePass = fixture.passMilliseconds / 10
        print("SIDEBAR-PASS workspaces=\(Self.workspaceCount) sessions=\(Self.sessionCount) rows=\(Self.personalRows().count) updates_per_s=\(Self.updates) passes_per_s=\(passes) pass_ms_per_s=\(String(format: "%.2f", ms)) one_pass_ms=\(String(format: "%.3f", onePass))")
        #expect(passes == 0, "\(passes) of \(Self.updates) session-record updates ran the sidebar pass")
    }

    /// What the pass draws still wakes it: a machine icon, and the personal order.
    @Test func anIconOrOrderChangeStillRunsThePass() throws {
        let fixture = try Fixture()
        fixture.reset()
        fixture.refetch(Self.personal(revision: 2, seen: 2_000, icon: "🚀"))
        #expect(fixture.passes == 1, "a machine icon change runs the pass once")
        let header = SidebarBridge.sections(fixture.services.machines, doc: fixture.services.sidebarDoc, profile: .defaultProfile)
            .lazy.compactMap(\.machine).first { $0.kind == .local }
        #expect(header?.icon == .emoji("🚀"), "the header draws the new icon")
        fixture.refetch(Self.personal(revision: 3, seen: 3_000, icon: "🚀", reversed: true))
        #expect(fixture.passes == 2, "a personal reorder runs the pass once")
        let listed = SidebarBridge.liveSections(fixture.services.machines, doc: fixture.services.sidebarDoc,
                                                registry: fixture.services.windows.registry, window: fixture.state).0
            .flatMap(\.workspaces).map(\.title).filter { $0.hasPrefix("Workspace ") }
        #expect(listed.first == "Workspace \(Self.workspaceCount - 1)", "the reversed personal order lists the last workspace first: \(listed.prefix(3))")
    }

    /// The cached order and per-session index answer as the per-pass sort and filter did.
    @Test func cachedOrderMatchesASortOfTheRows() throws {
        let fixture = try Fixture()
        let personal = fixture.services.machines.local.store.personal
        #expect(personal.workspacesInOrder == personal.workspaces.sorted { $0.index < $1.index })
        let filtered = Dictionary(personal.workspaces.filter { $0.sessionID == "s-3" }.map { ($0.workspaceKey.rawValue, $0) },
                                  uniquingKeysWith: { first, _ in first })
        #expect(personal.workspaces(session: "s-3") == filtered)
        #expect(personal.sessionIcon(Self.session)?.transport == .object(["kind": .string("local")]))
    }
}
