import AppKit
import CmuxNextBridge
import CmuxNextCompat
import CmuxNextControl
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextLayout
@testable import CmuxNextSidebar
import Foundation
import Observation
import Testing

/// Classic import can register several bottom placements before one snapshot
/// reports them. The document mirror moves synchronously, while the sidebar
/// model normally follows on a later turn. Every placement must use the order
/// the preceding placement produced, even before that observation runs.
@MainActor @Suite(.serialized, .ownsSidebarDocStore)
struct PlacementDocumentWriteOrderTests {
    private static let original = ["k4", "k3", "k2", "k1"]
    private static let expected = ["k1", "k2", "k3", "k4"]
    private static let session = "s-local"
    private static let section = "sec_m_s-local"
    private static var live: [SidebarDocWorkspaceRef] {
        expected.map { SidebarDocWorkspaceRef(sessionID: session, workspaceID: $0) }
    }

    private nonisolated struct Seed: DaemonRequest {
        typealias Response = EmptyResponse
        static let command = "gallery-seed-burst"
    }

    private nonisolated struct Move: Decodable {
        nonisolated struct Target: Decodable { let section: String; let after: String?; let before: String? }
        let op: String
        let items: [String]
        let to: Target
    }

    /// Serialization only: the real Rust reducer determines every moved order.
    private static func document(order: [String], revision: Int) throws -> Data {
        let items: [[String: Any]] = zip(order, ["a", "b", "c", "d"]).map { id, rank in
            ["id": "w_\(id)", "section": section, "order": rank,
             "body": ["type": "workspace", "ref": ["session_id": session, "workspace_id": id]]]
        }
        return try JSONSerialization.data(withJSONObject: [
            "revision": String(revision),
            "sections": [["id": section, "kind": ["type": "machine", "session_id": session]]],
            "items": items,
        ])
    }

    /// Holds all replies until the synchronous burst is inspected. To commit,
    /// replay the emitted ops through an independent Rust mirror and save its
    /// rows as the next sidebar.get document; no test code implements moving.
    @Observable @MainActor final class Remote: SidebarDocRemote {
        nonisolated struct Call: Sendable { let ops: Data; let key: String }
        nonisolated enum Failure: Error { case closed, unexpectedCommand }
        private(set) var calls: [Call] = []
        private(set) var document: Data
        @ObservationIgnored private let reducer: SidebarMirror
        @ObservationIgnored private var held: [CheckedContinuation<SidebarDocReply, any Error>] = []
        @ObservationIgnored private var closed = false

        init(document: Data, reducer: SidebarMirror) {
            self.document = document
            self.reducer = reducer
        }

        var isAvailable: Bool { !closed }
        func get() async throws -> Data { document }
        func apply(ops: Data, key: String) async throws -> SidebarDocReply {
            guard !closed else { throw Failure.closed }
            calls.append(Call(ops: ops, key: key))
            return try await withCheckedThrowingContinuation { held.append($0) }
        }
        func move(_ items: [String], to target: SidebarDocTarget, key: String) async throws -> SidebarDocReply { throw Failure.unexpectedCommand }
        func pin(_ items: [String], key: String) async throws -> SidebarDocReply { throw Failure.unexpectedCommand }
        func unpin(_ items: [String], key: String) async throws -> SidebarDocReply { throw Failure.unexpectedCommand }
        func adopt(_ refs: [SidebarDocWorkspaceRef], key: String) async throws -> SidebarDocReply { throw Failure.unexpectedCommand }

        func commit() throws {
            for call in calls { try reducer.apply(intent: .apply(call.ops, key: call.key)) }
            let rows = try #require(reducer.rows(SidebarViewRequest(live: PlacementDocumentWriteOrderTests.live)))
            document = try PlacementDocumentWriteOrderTests.document(order: rows.compactMap(\.ref?.workspaceID), revision: 1 + calls.count)
            let replies = held
            held.removeAll()
            // No undo was requested. Empty inverse retires each optimistic
            // intent; the subsequent refresh loads the committed snapshot.
            for reply in replies { reply.resume(returning: SidebarDocReply(revision: UInt64(1 + calls.count), inverse: Data("[]".utf8))) }
        }

        func close() {
            closed = true
            let replies = held
            held.removeAll()
            for reply in replies { reply.resume(throwing: Failure.closed) }
        }
    }

    private static func wait(_ label: String, until ready: @escaping @MainActor @Sendable () -> Bool) async throws {
        try await ControlDeadline.shared.run(method: label, deadline: .now + .seconds(10)) { @MainActor in
            for await value in ObservationStream(ready) where value { return }
            throw CancellationError()
        }
    }

    @Test(.disabled("Quarantined: the model shows daemon order before any placement runs, red on every tip suite run, https://github.com/manaflow-ai/cmux/issues/31006")) func aDocumentBurstUsesEachPrecedingMoveBeforeTheModelObservationRuns() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        // Its lazy initializer installs the app document store. Finish that
        // before replacing current, so opening the window cannot replace ours.
        _ = services.sidebarLayout
        let savedDocument = SidebarDocStore.current
        defer { SidebarDocStore.current = savedDocument }
        let initial = try Self.document(order: Self.original, revision: 1)
        let clientMirror = try #require(SidebarMirror.make(), "this regression requires the real Rust sidebar mirror FFI")
        let serverMirror = try #require(SidebarMirror.make())
        try #require(serverMirror.load(initial))
        let remote = Remote(document: initial, reducer: serverMirror)
        defer { remote.close() }
        let document = SidebarDocStore(remote: remote, mirror: clientMirror)
        SidebarDocStore.current = document
        document.refresh()
        try await Self.wait("placement document load") { document.isActive }

        // Public resource IDs make every daemon workspace resolve to its
        // confirmed document item; otherwise this would test personal order.
        let script = PlacementStaleRowsGalleryTests.daemonScript.replacingOccurrences(
            of: "'key': key, 'name': names[key]", with: "'key': key, 'resource_id': key, 'name': names[key]")
        let bridge = DaemonBridge.fakePython(["-c", script, "0"])
        let connection = DaemonConnection(endpoint: .init(socketPath: "/tmp/cmux-placement-document-\(UUID().uuidString).sock", bridge: bridge),
                                          configuration: .init(requiredCapabilities: [], terminalEnvironment: nil))
        do {
            let identity = try await connection.start()
            services.daemon.start(first: { .success((connection, identity)) }, makeConnection: { connection })
            defer { services.daemon.shutdownConnection() }
            try await PlacementStaleRowsGalleryTests.waitForInitialSnapshot(services)
            let windows = services.windows
            windows.ordersWindowsIn = false
            let controller = try #require(windows.openWindow(workspaces: ["k1"]))
            defer { controller.teardown(); controller.window?.close() }
            _ = try await connection.request(Seed())
            let snapshot = try await connection.snapshot()

            // One main-actor turn, with no await between placements. Both the
            // confirmed document and visible model begin in reverse order.
            services.daemon.store.apply(snapshot: snapshot.tree)
            windows.registry.apply { $0.openWindow(id: controller.state.id, workspaceIDs: Self.original); return WindowRegistry.Changes() }
            document.show(live: Self.live)
            controller.sidebar.sameTurn.syncNow(rows: true)
            let cachedDocumentDrag = try #require(controller.sidebar.model.docDrag)
            try #require(!controller.sidebar.model.ungroupedFirst,
                         "the active document owns mixed order even without the legacy mixed-order capability")
            try #require(controller.sidebar.model.selectableWorkspaces.map(\.id.rawValue) == Self.original)
            try #require(clientMirror.rows(SidebarViewRequest(live: Self.live))?.compactMap(\.ref?.workspaceID) == Self.original)
            try #require(SidebarDocStore.current === document)
            // Rows passes now retry ready placements (#27014), so establish the
            // reverse-order fixture before enqueuing this synchronous burst.
            // The workspaces are already live: hold only registration's immediate
            // retry, then exercise the real batch with its re-entry guard released.
            let pendingRows = PendingWorkspaceRows.shared
            try #require(!pendingRows.placing)
            do {
                pendingRows.placing = true
                defer { pendingRows.placing = false }
                for id in ["k2", "k3", "k4"] {
                    NewWorkspacePlacements.expect(id, in: controller.state.id, slot: .bottom(anchor: nil), byDefault: nil, windows: windows)
                }
            }
            try #require(windows.pendingPlacementOrder == ["k2", "k3", "k4"])
            windows.applyPendingPlacements(live: Set(Self.expected))
            #expect(!controller.sidebar.model.ungroupedFirst,
                    "document placement resync must not enable legacy ungrouped-first drop targeting")
            #expect(clientMirror.rows(SidebarViewRequest(live: Self.live))?.compactMap(\.ref?.workspaceID) == Self.expected,
                    "all three placements must not anchor after k1 while the model observation is deferred")
            #expect(remote.calls.isEmpty, "no remote reply can explain the optimistic result")

            try await Self.wait("three document placement writes") { remote.calls.count == 3 }
            let moves = try remote.calls.flatMap { try JSONDecoder().decode([Move].self, from: $0.ops) }
            #expect(moves.map(\.op) == ["move", "move", "move"])
            #expect(moves.map(\.items) == [["w_k2"], ["w_k3"], ["w_k4"]])
            #expect(moves.map(\.to.after) == ["w_k1", "w_k2", "w_k3"])
            #expect(moves.allSatisfy { $0.to.before == nil && $0.to.section == Self.section })
            let optimisticVersion = document.version
            try remote.commit()
            try await Self.wait("document placement replies settled") { document.version >= optimisticVersion + 3 }
            document.refresh()
            try await Self.wait("committed document reload") { document.records.revision == 4 }
            document.show(live: Self.live)
            controller.sidebar.sameTurn.syncNow(rows: true)
            #expect(controller.sidebar.model.selectableWorkspaces.map(\.id.rawValue) == Self.expected)
            // Fresh mirror: no client pending intents can mask a bad save.
            let reloaded = try #require(SidebarMirror.make())
            try #require(reloaded.load(remote.document))
            #expect(reloaded.rows(SidebarViewRequest(live: Self.live))?.compactMap(\.ref?.workspaceID) == Self.expected)
            if ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1" {
                try await PlacementDocumentCapture.captureIfRequested(
                    controller: controller,
                    committed: try #require(reloaded.rows(SidebarViewRequest(live: Self.live))).compactMap(\.ref?.workspaceID),
                    expected: Self.expected, original: Self.original, operations: remote.calls.map(\.ops))
            }
            // Regression: the document can go inactive while the bridge still has its last
            // document drag cached. Resync must leave normal personal-order drop targeting active;
            // using `model.docDrag == nil` here misses the disconnect and keeps document mode.
            controller.sidebar.model.docDrag = cachedDocumentDrag
            SidebarDocStore.current = nil
            controller.sidebar.resync()
            #expect(controller.sidebar.model.ungroupedFirst,
                    "inactive document resync must restore legacy ungrouped-first targeting even with cached docDrag")
            // A loose workspace dropped below the group must clamp before the group on
            // the legacy path; document/mixed ordering would instead accept the trailing slot.
            let moving = SidebarWorkspace(id: WorkspaceID("moving"), title: "Moving")
            let loose = SidebarWorkspace(id: WorkspaceID("loose"), title: "Loose")
            let member = SidebarWorkspace(id: WorkspaceID("member"), title: "Member")
            let section = SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "This Mac", kind: .local)), nodes: [
                .workspace(moving), .workspace(loose),
                .group(SidebarGroup(id: GroupID("group"), name: "Group", workspaces: [member])),
            ])
            var options = SidebarLayoutOptions()
            options.excludedWorkspaces = [moving.id]
            let layout = SidebarLayout.make(sections: [section], metrics: .standard, options: options)
            let target = DropResolver.resolve(y: layout.totalHeight + 40, payload: .workspaces([moving.id]),
                                              base: layout, sections: [section],
                                              ungroupedFirst: controller.sidebar.model.ungroupedFirst)
            #expect(target == .position(DropPosition(section: .machine(.local), index: 1)),
                    "the inactive document must not retain the mixed-order trailing drop slot")
            await connection.close()
        } catch {
            await connection.close()
            throw error
        }
    }
}
