import AppKit
import CmuxNextActions
import Foundation
import Testing
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
@testable import CmuxNextDaemon

/// #27934: a chat a Chief subagent started with `acpmux new` / `cmux acp new` runs in the Chief
/// home's acpmux, untagged (no `mux.parent`). Its tab, opened with `agent.openSessionTab` and only
/// a session id, was recorded as this Mac's chat, and the pane's router sent it to this Mac's
/// acpmux, which lacks it: "This chat isn't available". A tab attaches where its session runs,
/// whatever its tags, and the open actions record that host or refuse.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2)))
struct ChiefSubagentChatOpensWhereItRunsTests {
    private struct Reached: Error {
        let host: String
    }

    /// A pane host that says it was reached; whether it runs a session, its real acpmux host says.
    private struct NamedHost: AgentPaneHostProviding {
        let name: String
        var probe: (any AgentPaneHostProviding)?
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw Reached(host: name) }
        func sessionFolder(sessionId: String) async throws -> AgentPaneSessionFolder? { nil }
        func putFile(sessionId: String, name: String, data: Data) async throws -> String { "" }
        func runsSession(_ sessionId: String) async -> Bool? { await probe?.runsSession(sessionId) }
    }

    private func reached(_ host: any AgentPaneHostProviding, session: String) async -> String? {
        do {
            _ = try await host.handshake(sessionId: session)
            return nil
        } catch let reached as Reached {
            return reached.host
        } catch {
            return nil
        }
    }

    private let untagged = "01a20c11-7a0e-7c55-9d7b-27934aaaaaaa"
    private let tagged = "01a20c11-7a0e-7c55-9d7b-27934bbbbbbb"
    private let appOwn = "01a20c11-7a0e-7c55-9d7b-27934ccccccc"
    private let parentTag = "optchat-chief:0a1b2c3d"

    /// The Chief home's acpmux lists a subagent's chat started with `acpmux new` (no tags), one
    /// the Chief host started (`mux.parent`), and a chat that also runs on this Mac's acpmux.
    @Test func aTabAttachesWhereItsSessionRunsWhateverItsTags() async throws {
        let chiefDaemon = try ListingDaemon(sessions: [
            ["sessionId": untagged, "tags": ["lane.reportsTo": "01a20000"]],
            ["sessionId": tagged, "tags": ["mux.parent": parentTag]],
            ["sessionId": appOwn],
        ])
        let appDaemon = try ListingDaemon(sessions: [["sessionId": appOwn]])
        defer { chiefDaemon.stop(); appDaemon.stop() }
        let app = NamedHost(name: "app", probe: AcpmuxHost(environment: appDaemon.environment, startsDaemons: false))
        let router = AcpmuxChiefSessionRouter(local: app, chief: NamedHost(name: "chief"),
                                              chiefEnvironment: chiefDaemon.environment, parentTag: parentTag)

        // The issue's tab: recorded as this Mac's, its session only in the Chief home's acpmux.
        #expect(await reached(router, session: untagged) == "chief")
        #expect(await reached(router, session: tagged) == "chief")
        // A session this Mac's acpmux runs stays there, and so does one neither daemon lists.
        #expect(await reached(router, session: appOwn) == "app")
        #expect(await reached(router, session: "01a20c11-not-anywhere") == "app")
    }

    /// `runsSession` on a real socket: the daemon's exact resolve answers; with no daemon, a session
    /// its home keeps on disk is still its own, and anything else is unknown, never "no".
    @Test func anAcpmuxHostSaysWhichSessionsItRuns() async throws {
        let daemon = try ListingDaemon(sessions: [["sessionId": appOwn]])
        let host = AcpmuxHost(environment: daemon.environment, startsDaemons: false)
        #expect(await host.runsSession(appOwn) == true)
        #expect(await host.runsSession(untagged) == false)
        daemon.stop()
        try FileManager.default.createDirectory(at: daemon.environment.home.appendingPathComponent("sessions/\(untagged)"),
                                                withIntermediateDirectories: true)
        #expect(await host.runsSession(untagged) == true)
        #expect(await host.runsSession(appOwn) == nil)
    }

    private static func connected() throws -> DaemonIdentity {
        let json = #"{"app":"cmux-tui","protocol":1,"session":"chat-not-found-test","generation":"g1"}"#
        return try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8))
    }

    /// Services with one connected workspace whose store takes agent tabs: `made` gets each tab's
    /// record. This Mac's acpmux runs `appRuns`; the Chief home's (`chief:0a1b2c3d`) runs `chiefRuns`.
    private static func services(appRuns: Bool, chiefRuns: Bool,
                                 made: @escaping @MainActor (AgentSessionRef) -> Void) throws -> AppServices {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let store = services.daemon.store
        store.connectionState = .connected(try connected())
        let pane = PaneSnapshot(id: PaneID(rawValue: 1), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 1), title: "~")])
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: .leaf(PaneID(rawValue: 1)), panes: [pane])
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: nil, name: "w1", screens: [screen])]))
        let tabs = services.agentTabs
        tabs.localHost = AgentSessionRef.host(installID: "chat-not-found-test")
        tabs.chiefHost = "chief:0a1b2c3d"
        tabs.chiefPaneHost = SessionProbe(runs: chiefRuns)
        tabs.sessionProbe = SessionProbe(runs: appRuns)
        tabs.holdsTabs = { _ in true }
        tabs.reachable = { _ in true }
        tabs.create = { _, _, record, _, _, _ in
            made(record)
            return (AgentTabCreated(key: "tab-\(record.session ?? "")", surface: SurfaceID(rawValue: 9)), nil)
        }
        AppActions.bind(services)
        return services
    }

    private static func openTab(_ session: String, in services: AppServices) async throws -> Result<[String: ActionResultValue], ActionWorkFailure>? {
        let pane = try #require(services.daemon.store.workspaces.first?.screens.first?.panes.first)
        let invocation = ActionInvocation(target: ActionTargetRef(kind: .pane, id: pane.id),
                                          arguments: ["session": .string(session)], origin: .script)
        let run = services.registry.capturingRun { _ = services.registry.perform("agent.openSessionTab", invocation: invocation) }
        return await run.results.first?.value
    }

    /// `agent.openSessionTab` with only a session id records the Chief home's host when that
    /// daemon runs the chat, this Mac's when this Mac's does.
    @Test func openSessionTabRecordsTheHostThatRunsTheSession() async throws {
        var records: [AgentSessionRef] = []
        let services = try Self.services(appRuns: false, chiefRuns: true) { records.append($0) }
        try #require(services.agentTabs.canHostChat, "this build has no agent page")
        let opened = try await Self.openTab(untagged, in: services)
        guard case .success? = opened else { Issue.record("not opened: \(String(describing: opened))"); return }
        #expect(records.map(\.host) == ["chief:0a1b2c3d"])
        #expect(records.first?.session == untagged)

        records = []
        let local = try Self.services(appRuns: true, chiefRuns: false) { records.append($0) }
        guard case .success? = try await Self.openTab(appOwn, in: local) else { Issue.record("not opened"); return }
        #expect(records.map(\.host) == [try #require(local.agentTabs.localHost)])
    }

    /// A session no acpmux of this Mac runs makes no tab: the run fails with the reason, instead of
    /// a tab that says "This chat isn't available".
    @Test func openSessionTabRefusesASessionNoDaemonRuns() async throws {
        var records: [AgentSessionRef] = []
        let services = try Self.services(appRuns: false, chiefRuns: false) { records.append($0) }
        try #require(services.agentTabs.canHostChat, "this build has no agent page")
        let opened = try await Self.openTab("01a20c11-gone", in: services)
        guard case .failure(let failure)? = opened else { Issue.record("not refused: \(String(describing: opened))"); return }
        #expect(failure.message == MiscHandlerStrings.noLocalSession("01a20c11-gone"))
        #expect(failure.refusal == .unavailable)
        #expect(records.isEmpty, "a dead tab was made")
    }
}

/// A pane host that only says whether it runs a session (`runs` for every one).
struct SessionProbe: AgentPaneHostProviding {
    let runs: Bool?
    func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw CancellationError() }
    func sessionFolder(sessionId: String) async throws -> AgentPaneSessionFolder? { nil }
    func putFile(sessionId: String, name: String, data: Data) async throws -> String { "" }
    func runsSession(_ sessionId: String) async -> Bool? { runs }
}

/// A fake acpmux on a unix socket of its own: `_acpmux/sessions` lists `sessions`, and
/// `_acpmux/resolve` (exact) answers one of them or not-found (-32002), as acpmux does.
nonisolated final class ListingDaemon: @unchecked Sendable {  // the fd is written once in init and closed once in stop
    let environment: AcpmuxEnvironment
    private let root: URL
    private let descriptor: Int32

    init(sessions: [[String: any Sendable]]) throws {
        root = URL(fileURLWithPath: "/tmp/cnf-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true), home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let acpmux = bin.appendingPathComponent("acpmux")
        try "#!/bin/sh\nexit 1\n".write(to: acpmux, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: acpmux.path)
        let socketPath = home.appendingPathComponent("s.sock").path
        environment = try #require(AcpmuxEnvironment.resolve(
            build: nil, bundledBinDirectory: bin, environment: ["ACPMUX_HOME": home.path, "ACPMUX_SOCKET": socketPath],
            executableOverride: nil))
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: socketPath.utf8)
            buffer[socketPath.utf8.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(descriptor, 8) == 0 else { throw POSIXError(.EADDRINUSE) }
        let listener = descriptor
        let rows = try JSONSerialization.data(withJSONObject: sessions)
        Thread.detachNewThread {
            while true {
                let client = accept(listener, nil, nil)
                guard client >= 0 else { return }
                Thread.detachNewThread { Self.serve(client, rows: rows) }
            }
        }
    }

    /// Stops listening and removes the socket file (the home stays, for what it keeps on disk).
    func stop() {
        close(descriptor)
        try? FileManager.default.removeItem(atPath: environment.socketPath)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    private static func serve(_ client: Int32, rows data: Data) {
        defer { close(client) }
        let rows = (try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = recv(client, &chunk, chunk.count, 0)
            guard count > 0 else { return }
            buffer += Data(chunk[0..<count])
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let id = object["id"] else { continue }
                let params = object["params"] as? [String: Any] ?? [:]
                var reply: [String: Any] = ["jsonrpc": "2.0", "id": id]
                switch object["method"] as? String {
                case "_acpmux/sessions":
                    reply["result"] = ["sessions": rows]
                case "_acpmux/resolve":
                    if let row = rows.first(where: { $0["sessionId"] as? String == params["sessionId"] as? String }) {
                        reply["result"] = ["session": row]
                    } else {
                        reply["error"] = ["code": -32002, "message": "no such session"]
                    }
                default:
                    reply["result"] = ["protocolVersion": 1]
                }
                guard var out = try? JSONSerialization.data(withJSONObject: reply) else { continue }
                out.append(0x0A)
                _ = out.withUnsafeBytes { send(client, $0.baseAddress, out.count, 0) }
            }
        }
    }
}
