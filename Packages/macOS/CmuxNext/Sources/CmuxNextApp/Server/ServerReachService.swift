import AppKit
import CmuxNextDaemon
import CmuxNextRemote
import Foundation
import Observation
import os
import SystemConfiguration

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
    /// The app's own bundled `cmux` (overlay bridge and link reads).
    private let cli: URL?
    private let local: @MainActor () -> ServerReachPlan.LocalServer?
    /// This Mac's link (running or not) and its paired installs, or nil (no link).
    private let linkPeers: @MainActor () async -> ServerReachPlan.LinkPeers?
    private let makeWatcher: LocalServerSource.MakeWatcher
    private var linkWatchers: [any ServerFileWatching] = []
    private var watchedLinkFiles: [String] = []
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.server-reach")
    private var observers: [Task<Void, Never>] = []
    private var reading: Task<Void, Never>?
    /// Another read was asked for while one ran: run once more after it.
    private var readAgain = false
    /// Hosts removed in this run, so a stale registry echo does not bring them back.
    private var removed: Set<String> = []
    private(set) var lastPlan: ServerReachPlan?
    /// Set while an administrator turned remote hosts off: no server connects.
    private(set) var policyDisabled = false

    init(machines: MachineRegistry, call: @escaping Call, signedInUser: @escaping @MainActor () -> String?, paths: SSHPaths,
         binary: URL?, local: @escaping @MainActor () -> ServerReachPlan.LocalServer? = { nil },
         linkPeers: @escaping @MainActor () async -> ServerReachPlan.LinkPeers? = { nil }, cli: URL? = nil,
         makeWatcher: @escaping LocalServerSource.MakeWatcher = LocalServerSource.fileWatcher) {
        self.makeWatcher = makeWatcher
        self.cli = cli
        self.machines = machines
        self.call = call
        self.signedInUser = signedInUser
        self.paths = paths
        self.binary = binary
        self.local = local
        self.linkPeers = linkPeers
    }

    func start() {
        let machines = machines, signedInUser = signedInUser
        observers.append(Task { [weak self] in
            var previous: String?
            for await user in Observations({ signedInUser() }) {
                guard let self else { return }
                // Servers belong to the account: any change of user closes them.
                if previous != nil, user != previous { self.closeAll() }
                previous = user
                if user != nil {
                    self.restore(self.currentRecords())
                    self.refresh()
                }
            }
        })
        observers.append(Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification) {
                self?.refresh()
                guard let self, !self.policyDisabled else { continue }
                for server in self.machines.servers where server.autoConnect { server.wake() }
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
        // A server on this Mac connects only once the home daemon's identity
        // is known, so the admit check can refuse a route back to it.
        observers.append(Task { [weak self] in
            for await known in Observations({ machines.local.identity != nil }) where known {
                guard let self, !self.policyDisabled else { continue }
                for server in self.machines.servers where server.autoConnect { server.connect() }
            }
        })
    }

    /// Turning remote hosts off disconnects every server (they stay listed
    /// and connect again when the policy allows).
    func applyPolicy(disabled: Bool) {
        guard disabled != policyDisabled else { return }
        policyDisabled = disabled
        for server in machines.servers {
            server.daemon.policyBlock.set(disabled)
            if disabled { server.disconnect() } else if server.autoConnect { server.connect() }
        }
    }

    private func currentRecords() -> [SessionRecord] {
        let store = machines.local.store
        return store.personal.isLoaded && !store.isProvisional ? store.personal.sessions : []
    }

    func stop() {
        watchLink([])
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
        guard let user = signedInUser() else { return }
        do {
            let chiefs = try ServerReachPlan.parseChiefs(
                try CloudPairingSource.okValue(try await call("v1/read", ["op": "chief.list", "params": [String: Any]()])))
            let hosts = try await readHosts()
            // A read that a sign-out or an account switch overtook applies nothing.
            guard !Task.isCancelled, signedInUser() == user else { return }
            let link = await linkPeers()
            watchLink(link?.watchedFiles ?? [])
            guard !Task.isCancelled, signedInUser() == user else { return }
            let plan = ServerReachPlan.make(chiefs: chiefs, hosts: hosts, local: local(), link: link)
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
            let page = try ServerReachPlan.parseHosts(try CloudPairingSource.okValue(try await call("v1/read", ["op": "team.hosts.list", "params": params])))
            hosts += page.hosts
            guard let next = page.next, !next.isEmpty else { return hosts }
            cursor = next
        }
        // A directory larger than the cap is a partial read: never act on it.
        throw ServerReachPlan.ReadError.tooManyHosts
    }

    /// Adds the servers that should show and removes (and forgets) the rest.
    func apply(_ desired: [ServerReach]) async {
        let change = ServerReachPlan.diff(shown: machines.servers.map(\.reach), desired: desired)
        for reach in change.add {
            removed.remove(reach.hostID)
            add(reach, connect: true)
        }
        for machineID in change.remove { await remove(machineID) }
        for reach in change.reroute { reroute(reach) }
    }

    /// Replaces a shown server's session with one on its new route; the
    /// registry record (same session) stays.
    private func reroute(_ reach: ServerReach) {
        guard let old = machines.removeServer(reach.machineID) else { return }
        let connect = old.autoConnect
        old.close()
        logger.info("server \(reach.name, privacy: .public) re-routed")
        add(reach, connect: connect)
    }

    /// Watches the link's pairing file and its registration (kernel vnode
    /// events, no polling): a peer added or removed, or the link starting or
    /// stopping, re-reads, so a server gets the overlay route (or loses it)
    /// without a relaunch. A missing file is watched until it appears.
    private func watchLink(_ files: [String]) {
        guard files != watchedLinkFiles else { return }
        for watcher in linkWatchers { watcher.stop() }
        watchedLinkFiles = files
        linkWatchers = files.map { file in
            let watcher = makeWatcher(URL(fileURLWithPath: file)) { [weak self] in
                // task-owner: one main-actor hop per file event; refresh coalesces reads
                Task { @MainActor in self?.refresh() }
            }
            watcher.start()
            return watcher
        }
    }

    /// Restores servers the registry holds that this run has not seen.
    private func restore(_ records: [SessionRecord]) {
        guard signedInUser() != nil else { return }
        for record in records {
            guard let fields = record.transport.flatMap(SSHService.fields), let reach = ServerReach(transportFields: fields),
                  !removed.contains(reach.hostID), machines.server(reach.machineID) == nil else { continue }
            // A `unix` record restores only this Mac's own brain socket.
            if case .unix(let path) = reach.route, path != local()?.brainSocket { continue }
            add(reach, connect: fields["connect"] != "false")
        }
    }

    private func add(_ reach: ServerReach, connect: Bool) {
        guard machines.server(reach.machineID) == nil else { return }
        let session = ServerMachineSession(reach: reach, binary: binary, paths: paths, environment: SSHService.environment,
                                           localIdentity: { [machines] in machines.local.identity }, cli: cli)
        session.daemon.workTracker = machines.local.workTracker
        machines.add(session)
        logger.info("server \(reach.name, privacy: .public) (\(reach.hostID, privacy: .public)) added")
        session.autoConnect = connect
        if policyDisabled || machines.isFeatureDisabled(.remoteHosts) {
            session.daemon.policyBlock.set(policyDisabled)
        } else if connect {
            session.connect()
        }
    }

    /// Closes the server's session and removes it, with its registry record
    /// and personal organization, from the home session.
    private func remove(_ machineID: String) async {
        guard let session = machines.removeServer(machineID) else { return }
        removed.insert(session.reach.hostID)
        // Forget only this server's own record: the one whose transport names
        // its host; the daemon's identity counts only when it is that record.
        let reported = session.daemon.identity?.sessionID
        let sessionID = recordID(for: session.reach) ?? reported.flatMap { id in
            machines.local.store.personal.session(id) == nil ? nil : id
        }
        session.close()
        logger.info("server \(session.reach.name, privacy: .public) removed")
        guard let sessionID, sessionID != machines.local.identity?.sessionID, machines.local.supports(DaemonCapabilities.shared.profiles), let home = machines.local.connection else { return }
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

    /// This Mac as a possible placed server: every name it answers to
    /// (gethostname, LocalHostName, computer name) and the brain's daemon
    /// socket, when one exists (a stat; nothing is read).
    static func thisMac() -> ServerReachPlan.LocalServer? {
        let socket = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cmux/brains/chief/daemon/cmux.sock").path
        guard FileManager.default.fileExists(atPath: socket) else { return nil }
        var names: [String] = []
        var buffer = [CChar](repeating: 0, count: 256)
        if gethostname(&buffer, buffer.count) == 0 {
            names.append(String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
        }
        if let local = SCDynamicStoreCopyLocalHostName(nil) as String? { names.append(local) }
        if let computer = SCDynamicStoreCopyComputerName(nil, nil) as String? { names.append(computer) }
        let short = names.compactMap { $0.split(separator: ".").first.map(String.init) }.filter { !$0.isEmpty }
        return short.isEmpty ? nil : ServerReachPlan.LocalServer(hostNames: short, brainSocket: socket)
    }

    /// This Mac's link through the bundled CLI (`cmux link show`, `cmux link
    /// peer list`), running or not: nil when the CLI is missing or `show`
    /// fails (no link set up here).
    nonisolated static func readLinkPeers(binary: URL?) async -> ServerReachPlan.LinkPeers? {
        guard let binary else { return nil }
        func run(_ arguments: [String]) async -> Data? {
            guard let result = try? await ProcessRunner.run(executable: binary, arguments: arguments, environment: nil,
                                                            timeout: .seconds(10), clock: ContinuousClock()),
                  result.status == 0 else { return nil }
            return result.stdout
        }
        guard let show = await run(["link", "show"]) else { return nil }
        return ServerReachPlan.linkPeers(show: show, peers: await run(["link", "peer", "list"]))
    }

    /// The registry transport for `session`: the reach plus whether it connects at launch.
    static func transport(_ session: ServerMachineSession) -> JSONValue {
        var fields = session.reach.transportFields.mapValues(JSONValue.string)
        fields["connect"] = .string(session.autoConnect ? "true" : "false")
        return .object(fields)
    }
}
