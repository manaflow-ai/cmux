import AppKit
import CmuxNextDaemon
import CmuxNextRemote
import Foundation
import Observation
import os

/// Paired servers in the sidebar (plans/cmux-next/server-reach.md): when the
/// signed-in user has a chief placed on a paired server, that server's
/// Chief brain session joins `MachineRegistry` as a `server` machine, so the
/// workspaces the brain opens for subagents show under the server's name.
///
/// Sources: `chief.list` (which servers run a chief) and `team.hosts.list`
/// (which servers are still paired), read as the signed-in user. They are
/// read at sign-in, when the app becomes active, after Add Server places a
/// chief, and on `refresh()`; never on a timer. A server whose host left
/// the directory (`server.revoke`) or no longer runs a chief is closed and
/// forgotten in the session registry. A failed read changes nothing.
///
/// Sessions the registry holds (recorded by `SessionRegistrar` after the
/// first connect) come back at launch before the first read, so an offline
/// server shows as unreachable at once; connecting never blocks the UI.
@MainActor
final class ServerReachService {
    typealias Call = CloudChiefs.Call

    private let machines: MachineRegistry
    private let call: Call
    /// The signed-in user's id, or nil when signed out (observed).
    private let signedInUser: @MainActor () -> String?
    private let paths: SSHPaths
    private let binary: URL?
    private let local: @MainActor () -> ServerReachPlan.LocalServer?
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.server-reach")
    private var observers: [Task<Void, Never>] = []
    private var reading: Task<Void, Never>?
    /// Another read was asked for while one ran: run once more after it.
    private var readAgain = false
    /// Hosts removed in this run, so a stale registry echo does not bring them back.
    private var removed: Set<String> = []
    private(set) var lastPlan: ServerReachPlan?

    init(machines: MachineRegistry, call: @escaping Call, signedInUser: @escaping @MainActor () -> String?, paths: SSHPaths,
         binary: URL?, local: @escaping @MainActor () -> ServerReachPlan.LocalServer? = { nil }) {
        self.machines = machines
        self.call = call
        self.signedInUser = signedInUser
        self.paths = paths
        self.binary = binary
        self.local = local
    }

    func start() {
        let machines = machines, signedInUser = signedInUser
        observers.append(Task { [weak self] in
            var previous: String?
            for await user in Observations({ signedInUser() }) {
                guard let self else { return }
                if user == nil, previous != nil { self.closeAll() }
                previous = user
                if user != nil { self.refresh() }
            }
        })
        observers.append(Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification) {
                self?.refresh()
                for server in self?.machines.servers ?? [] where server.autoConnect { server.wake() }
            }
        })
        observers.append(Task { [weak self] in
            for await records in Observations({ () -> [SessionRecord] in
                let store = machines.local.store
                return store.personal.isLoaded && !store.isProvisional ? store.personal.sessions : []
            }) {
                self?.restore(records)
            }
        })
    }

    func stop() {
        for observer in observers { observer.cancel() }
        observers.removeAll()
        reading?.cancel()
        for server in machines.servers { server.close() }
    }

    /// Reads the user's placed chiefs and paired hosts once and applies them;
    /// a call during a read runs one more read after it.
    func refresh() {
        guard signedInUser() != nil else { return }
        guard reading == nil else {
            readAgain = true
            return
        }
        reading = Task { [weak self] in
            await self?.read()
            guard let self else { return }
            reading = nil
            if readAgain {
                readAgain = false
                refresh()
            }
        }
    }

    /// One read and apply (`refresh` serializes these). A failed read changes nothing.
    func read() async {
        do {
            let chiefs = try await CloudChiefs.list(call: call)
            let hosts = try await readHosts()
            guard !Task.isCancelled, signedInUser() != nil else { return }
            let plan = ServerReachPlan.make(chiefs: chiefs, hosts: hosts, local: local())
            lastPlan = plan
            for name in plan.unroutable { logger.error("server \(name, privacy: .public): no route to its chief session") }
            await apply(plan.desired)
        } catch {
            logger.error("server reach read failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Every page of `team.hosts.list` (bounded).
    private func readHosts() async throws -> [PairedServer] {
        var hosts: [PairedServer] = []
        var cursor: String?
        for _ in 0..<20 {
            var params: [String: Any] = ["limit": 100]
            if let cursor { params["cursor"] = cursor }
            let page = ServerReachPlan.parseHosts(try CloudPairingSource.okValue(try await call("v1/read", ["op": "team.hosts.list", "params": params])))
            hosts += page.hosts
            guard let next = page.next, !next.isEmpty else { break }
            cursor = next
        }
        return hosts
    }

    /// Adds the servers that should show and removes (and forgets) the rest.
    func apply(_ desired: [ServerReach]) async {
        let change = ServerReachPlan.diff(shown: machines.servers.map(\.reach), desired: desired)
        for reach in change.add {
            removed.remove(reach.hostID)
            add(reach, connect: true)
        }
        for machineID in change.remove { await remove(machineID) }
    }

    /// Restores servers the registry holds that this run has not seen.
    private func restore(_ records: [SessionRecord]) {
        guard signedInUser() != nil else { return }
        for record in records {
            guard let fields = record.transport.flatMap(SSHService.fields), let reach = ServerReach(transportFields: fields),
                  !removed.contains(reach.hostID), machines.server(reach.machineID) == nil else { continue }
            add(reach, connect: fields["connect"] != "false")
        }
    }

    private func add(_ reach: ServerReach, connect: Bool) {
        guard machines.server(reach.machineID) == nil else { return }
        let session = ServerMachineSession(reach: reach, binary: binary, paths: paths, environment: SSHService.environment,
                                           localIdentity: { [machines] in machines.local.identity })
        session.daemon.workTracker = machines.local.workTracker
        machines.add(session)
        logger.info("server \(reach.name, privacy: .public) (\(reach.hostID, privacy: .public)) added")
        if connect, !machines.isFeatureDisabled(.remoteHosts) { session.connect() } else { session.autoConnect = connect }
    }

    /// Closes the server's session and removes it, with its registry record
    /// and personal organization, from the home session.
    private func remove(_ machineID: String) async {
        guard let session = machines.removeServer(machineID) else { return }
        removed.insert(session.reach.hostID)
        let sessionID = session.daemon.identity?.sessionID ?? recordID(for: session.reach)
        session.close()
        logger.info("server \(session.reach.name, privacy: .public) removed")
        guard let sessionID, machines.local.supports(DaemonCapabilities.shared.profiles), let home = machines.local.connection else { return }
        do {
            _ = try await home.forgetSession(sessionID, force: true)
        } catch {
            logger.error("forget-session \(sessionID, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Sign-out: the servers belong to the account; their records stay for
    /// the next sign-in's read to keep or forget.
    private func closeAll() {
        for session in machines.servers {
            session.close()
            _ = machines.removeServer(session.machineID)
        }
    }

    private func recordID(for reach: ServerReach) -> String? {
        machines.local.store.personal.sessions.first { record in
            record.transport.flatMap(SSHService.fields).flatMap(ServerReach.init(transportFields:))?.hostID == reach.hostID
        }?.id
    }

    /// This Mac as a possible placed server: its short host name and the
    /// brain's daemon socket, when one exists (a stat; nothing is read).
    static func thisMac() -> ServerReachPlan.LocalServer? {
        let socket = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cmux/brains/chief/daemon/cmux.sock").path
        guard FileManager.default.fileExists(atPath: socket) else { return nil }
        var buffer = [CChar](repeating: 0, count: 256)
        guard gethostname(&buffer, buffer.count) == 0 else { return nil }
        let name = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        guard let short = name.split(separator: ".").first.map(String.init), !short.isEmpty else { return nil }
        return ServerReachPlan.LocalServer(hostName: short, brainSocket: socket)
    }

    /// The registry transport for `session`: the reach plus whether it connects at launch.
    static func transport(_ session: ServerMachineSession) -> JSONValue {
        var fields = session.reach.transportFields.mapValues(JSONValue.string)
        fields["connect"] = .string(session.autoConnect ? "true" : "false")
        return .object(fields)
    }
}
