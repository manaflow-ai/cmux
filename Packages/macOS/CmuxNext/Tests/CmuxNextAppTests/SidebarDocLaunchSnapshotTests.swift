import Foundation
@testable import CmuxNextDaemon
@testable import CmuxNextSidebar
import Testing

/// Pinned rows at launch (Lawrence 2026-10-29, NIGHTLY 6c1a5ab: "i just updated and pinning is broken", then
/// "pinnedd stuff is back but it took a lon time"). The pinned band is the sidebar document's, which the app
/// read only with `sidebar.get` after the daemon's handshake: 10.5 s after that launch (registry integrity
/// check, snapshot restore, terminal host adopt). The workspace rows drew at once from the launch snapshot, the
/// pins did not. The launch snapshot now carries the document (`sidebar_doc`), and the store shows it before the
/// daemon answers, so the band draws in the first sidebar frame.
@MainActor @Suite(.serialized) struct SidebarDocLaunchSnapshotTests {
    static let session = "s-local"
    static let pinnedRef = SidebarDocWorkspaceRef(sessionID: session, workspaceID: "ws-pinned")
    static let document = #"""
    {"revision":"7","sections":[{"id":"sec_pinned","kind":{"type":"pinned"}},
                                {"id":"sec_m_s-local","kind":{"type":"machine","session_id":"s-local"}}],
     "items":[{"id":"itm_pin","section":"sec_pinned","order":"a",
               "body":{"type":"workspace","ref":{"session_id":"s-local","workspace_id":"ws-pinned"}}},
              {"id":"itm_loose","section":"sec_m_s-local","order":"a",
               "body":{"type":"workspace","ref":{"session_id":"s-local","workspace_id":"ws-loose"}}}]}
    """#

    /// The home daemon still starting: not connected, `sidebar.get` never answers.
    private final class Starting: SidebarDocRemote {
        var isAvailable = false
        var gets = 0
        func get() async throws -> Data {
            gets += 1
            return Data(SidebarDocLaunchSnapshotTests.document.utf8)
        }
        func move(_ items: [String], to target: SidebarDocTarget, key: String) async throws -> SidebarDocReply { throw CancellationError() }
        func pin(_ items: [String], key: String) async throws -> SidebarDocReply { throw CancellationError() }
        func unpin(_ items: [String], key: String) async throws -> SidebarDocReply { throw CancellationError() }
        func adopt(_ refs: [SidebarDocWorkspaceRef], key: String) async throws -> SidebarDocReply { throw CancellationError() }
        func apply(ops: Data, key: String) async throws -> SidebarDocReply { throw CancellationError() }
    }

    private static func pinnedValues(_ store: SidebarDocStore) -> [String] {
        store.shown?.layout.section(LayoutSectionID(SidebarDocStore.pinnedSection))?.items.map(\.ref.value) ?? []
    }

    @Test func theLaunchSnapshotDocumentDrawsThePinnedBandBeforeTheDaemonAnswers() throws {
        let remote = Starting()
        let store = SidebarDocStore(remote: remote)
        let live = [Self.pinnedRef, SidebarDocWorkspaceRef(sessionID: Self.session, workspaceID: "ws-loose")]

        #expect(store.loadProvisional(Data(Self.document.utf8)))
        store.show(live: live)
        #expect(store.isActive && store.isProvisional)
        #expect(Self.pinnedValues(store) == ["s-local:ws-pinned"], "the pinned band waits for the daemon's sidebar.get")

        // The follow refreshes on every connection change; while the daemon is not up it must keep the snapshot's band.
        store.refresh()
        store.show(live: live)
        #expect(Self.pinnedValues(store) == ["s-local:ws-pinned"], "a refresh before the handshake dropped the band")
        #expect(remote.gets == 0)
    }

    @Test func theDaemonsLoadReplacesTheSnapshotDocument() async throws {
        let remote = Starting()
        let store = SidebarDocStore(remote: remote)
        #expect(store.loadProvisional(Data(Self.document.utf8)))
        remote.isAvailable = true
        store.refresh()
        await RapidWorkspaceCreateTests.wait(within: .seconds(10)) { !store.isProvisional }
        #expect(!store.isProvisional && store.isActive)
        #expect(remote.gets == 1)
        // A second snapshot never replaces the daemon's document.
        #expect(!store.loadProvisional(Data(Self.document.utf8)))
    }

    /// The daemon under the launch's load: its first `sidebar.get` answers (times out at 2 s) a few times.
    private final class Loaded: SidebarDocRemote {
        var failures: Int
        var gets = 0
        init(failures: Int) { self.failures = failures }
        var isAvailable: Bool { true }
        func get() async throws -> Data {
            gets += 1
            if gets <= failures { throw CancellationError() }
            return Data(SidebarDocLaunchSnapshotTests.document.utf8)
        }
        func move(_ items: [String], to target: SidebarDocTarget, key: String) async throws -> SidebarDocReply { throw CancellationError() }
        func pin(_ items: [String], key: String) async throws -> SidebarDocReply { throw CancellationError() }
        func unpin(_ items: [String], key: String) async throws -> SidebarDocReply { throw CancellationError() }
        func adopt(_ refs: [SidebarDocWorkspaceRef], key: String) async throws -> SidebarDocReply { throw CancellationError() }
        func apply(ops: Data, key: String) async throws -> SidebarDocReply { throw CancellationError() }
    }

    /// A first load that timed out was never asked for again (only unanswered changes retried), so the band
    /// stayed missing until a later reconnect: "pinnedd stuff is back but it took a lon time".
    @Test func aFirstLoadThatTimedOutIsAskedAgain() async {
        let remote = Loaded(failures: 3)
        let store = SidebarDocStore(remote: remote)
        store.refresh()
        await RapidWorkspaceCreateTests.wait(within: .seconds(10)) { store.isActive }
        #expect(store.isActive, "the sidebar document never loaded after \(remote.gets) asks")
        #expect(remote.gets == 4)
    }

    @Test func aDaemonThatDoesNotServeTheDocumentDropsTheSnapshot() {
        let store = SidebarDocStore(remote: Starting())
        #expect(store.loadProvisional(Data(Self.document.utf8)))
        store.dropProvisional()
        #expect(!store.isActive && store.shown == nil)
    }

    @Test func theLaunchSnapshotFileCarriesTheDocument() throws {
        let file = #"{"schema_version":1,"session":"cmux-app","tree":{"workspaces":[]},"sidebar_doc":"#
            + Self.document + "}"
        let snapshot = try #require(LaunchSnapshot.decode(Data(file.utf8), session: "cmux-app"))
        let data = try #require(snapshot.sidebarDoc, "the launch snapshot's sidebar document was not read")
        let store = SidebarDocStore(remote: Starting())
        #expect(store.loadProvisional(data))
        store.show(live: [Self.pinnedRef])
        #expect(Self.pinnedValues(store) == ["s-local:ws-pinned"])
    }

    @Test func anOlderDaemonsFileHasNoDocument() throws {
        let file = #"{"schema_version":1,"session":"cmux-app","tree":{"workspaces":[]}}"#
        let snapshot = try #require(LaunchSnapshot.decode(Data(file.utf8), session: "cmux-app"))
        #expect(snapshot.sidebarDoc == nil)
    }
}
