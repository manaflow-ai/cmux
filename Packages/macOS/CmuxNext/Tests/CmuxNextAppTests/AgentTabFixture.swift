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

    let service = DaemonService()
    /// The tree the app shows: the daemon's confirmed tabs plus the store's intents.
    var daemon: DaemonStore { service.store }
    let tabs: AgentTabStore
    private(set) var tabJSON: [String] = []
    private(set) var keys: [String] = []
    private(set) var binds: [(key: String, session: String)] = []
    /// The session each bind expected the store to have.
    private(set) var bindExpectations: [String?] = []
    /// The store's answer to the next bind.
    var bindAnswer = AgentSessionBindOutcome.taken
    private(set) var creations: [(record: AgentSessionRef, idempotencyKey: String)] = []
    /// Runs inside each creation before the store answers (a test holds the answer back).
    var holdCreate: (@MainActor () async -> Void)?

    init(registry: ActionRegistry = .standard(), linkScheme: String? = nil, tree: [String] = []) throws {
        tabs = AgentTabStore(tag: nil, registry: registry, environment: Self.mock, linkScheme: linkScheme)
        tabs.localHost = Self.host
        tabs.holdsTabs = { _ in true }
        tabs.reachable = { _ in true }
        tabJSON = tree
        try apply()
        let daemon = daemon
        tabs.lookup = { key in daemon.tab(id: key)?.agentSession.map { (record: $0, store: daemon) } }
        tabs.listTabs = {
            daemon.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).compactMap { tab in tab.agentSession.map { (key: tab.id, record: $0) } }
        }
        tabs.create = { [unowned self] _, _, record, key, _ in
            await holdCreate?()
            if let index = creations.firstIndex(where: { $0.idempotencyKey == key }) {
                return (AgentTabCreated(key: keys[index], surface: SurfaceID(rawValue: UInt64(index + 100))), 0)
            }
            let surface = keys.count + 100
            let id = "tab_agent\(surface)"
            tabJSON.append(Self.tab(surface, id, record))
            keys.append(id)
            creations.append((record, key))
            try apply()
            // Sequence 0: the tree already has the tab, so the provisional one settles at once.
            return (AgentTabCreated(key: id, surface: SurfaceID(rawValue: UInt64(surface))), 0)
        }
        tabs.bind = { [unowned self] key, _, expected, session in
            binds.append((key, session))
            bindExpectations.append(expected)
            guard bindAnswer == .taken else { return (bindAnswer, nil) }
            // The daemon's record takes the session before its reply (sequence 0: applied).
            try? setSession(session, of: key)
            return (.taken, 0)
        }
    }

    /// The agent chat tabs the pane shows now.
    var shownAgentTabs: [TabModel] {
        daemon.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).filter { $0.agentSession != nil }
    }

    /// A terminal tab and the tabs created so far, in one pane.
    func apply() throws {
        daemon.apply(snapshot: try ReopenClosedTabTests.tree([ReopenClosedTabTests.tab(1, "a", cwd: "/tmp")] + tabJSON))
    }

    /// The daemon's record of tab `key` now names `session`.
    func setSession(_ session: String, of key: String) throws {
        guard let index = tabJSON.firstIndex(where: { $0.contains("\"\(key)\"") }) else { return }
        let entry = tabJSON[index]
        guard let range = entry.range(of: #""session":(null|"[^"]*")"#, options: .regularExpression) else { return }
        tabJSON[index] = entry.replacingCharacters(in: range, with: "\"session\":\"\(session)\"")
        try apply()
    }

    /// Drops agent tab `key` from the tree, as a close by another client would.
    func remove(_ key: String) throws {
        tabJSON.removeAll { $0.contains("\"\(key)\"") }
        try apply()
    }

    func open(session: String? = nil, linked: Bool = false, key: String = UUID().uuidString) async throws -> String {
        try await tabs.open(in: 3, of: service, session: session, linked: linked, idempotencyKey: key).value().key
    }

    nonisolated static func tab(_ surface: Int, _ id: String, _ record: AgentSessionRef) -> String {
        let session = record.session.map { "\"\($0)\"" } ?? "null"
        let harness = record.harness.map { "\"\($0)\"" } ?? "null"
        let hostName = record.hostName.map { "\"\($0)\"" } ?? "null"
        return #"{"surface":\#(surface),"kind":"conversation","browser_renderer":"frontend","tab_resource_id":"\#(id)","title":"about:blank","conversation":{"agent_session":{"host":"\#(record.host)","host_name":\#(hostName),"session":\#(session),"harness":\#(harness)}}}"#
    }

    static func connect(_ daemon: DaemonStore) throws {
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(ReopenClosedTabTests.identify.utf8))
        _ = daemon.apply(.connected(identity, generationChanged: false))
    }
}
