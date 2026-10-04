import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import Foundation

/// Agent chat tabs over a real `DaemonStore` tree without a daemon: a created tab is added to the
/// tree as the store would report it (a `conversation` tab on an acpmux session), and a bind
/// rewrites its record.
@MainActor
final class AgentTabFixture {
    nonisolated static let host = "install:test-mac"
    static let mock = ["CMUX_NEXT_AGENT_PANE_MOCK": "1"]

    let daemon = DaemonStore()
    let service = DaemonService()
    let tabs: AgentTabStore
    private(set) var tabJSON: [String] = []
    private(set) var keys: [String] = []
    private(set) var binds: [(key: String, session: String)] = []
    private(set) var creations: [(record: AgentSessionRef, idempotencyKey: String)] = []

    init(registry: ActionRegistry = .standard(), linkScheme: String? = nil, tree: [String] = []) throws {
        tabs = AgentTabStore(tag: nil, registry: registry, environment: Self.mock, linkScheme: linkScheme)
        tabs.localHost = Self.host
        tabs.holdsTabs = { _ in true }
        tabJSON = tree
        try apply()
        let daemon = daemon
        tabs.lookup = { key in daemon.tab(id: key)?.agentSession.map { (record: $0, store: daemon) } }
        tabs.listTabs = {
            daemon.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).compactMap { tab in tab.agentSession.map { (key: tab.id, record: $0) } }
        }
        tabs.create = { [unowned self] _, _, record, key in
            if let index = creations.firstIndex(where: { $0.idempotencyKey == key }) {
                return AgentTabCreated(key: keys[index], surface: SurfaceID(rawValue: UInt64(index + 100)))
            }
            let surface = keys.count + 100
            let id = "tab_agent\(surface)"
            tabJSON.append(Self.tab(surface, id, record))
            keys.append(id)
            creations.append((record, key))
            try apply()
            return AgentTabCreated(key: id, surface: SurfaceID(rawValue: UInt64(surface)))
        }
        tabs.bind = { [unowned self] key, session in binds.append((key, session)) }
    }

    /// A terminal tab and the tabs created so far, in one pane.
    func apply() throws {
        daemon.apply(snapshot: try ReopenClosedTabTests.tree([ReopenClosedTabTests.tab(1, "a", cwd: "/tmp")] + tabJSON))
    }

    /// Drops agent tab `key` from the tree, as a close by another client would.
    func remove(_ key: String) throws {
        tabJSON.removeAll { $0.contains("\"\(key)\"") }
        try apply()
    }

    func open(session: String? = nil, linked: Bool = false, key: String = UUID().uuidString) async throws -> String {
        try await tabs.open(in: 3, of: service, session: session, linked: linked, idempotencyKey: key).key
    }

    nonisolated static func tab(_ surface: Int, _ id: String, _ record: AgentSessionRef) -> String {
        let session = record.session.map { "\"\($0)\"" } ?? "null"
        let harness = record.harness.map { "\"\($0)\"" } ?? "null"
        return #"{"surface":\#(surface),"kind":"conversation","browser_renderer":"frontend","tab_resource_id":"\#(id)","title":"about:blank","conversation":{"agent_session":{"host":"\#(record.host)","session":\#(session),"harness":\#(harness)}}}"#
    }

    static func connect(_ daemon: DaemonStore) throws {
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(ReopenClosedTabTests.identify.utf8))
        _ = daemon.apply(.connected(identity, generationChanged: false))
    }
}
