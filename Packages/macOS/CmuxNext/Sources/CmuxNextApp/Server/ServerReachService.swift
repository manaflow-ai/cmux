import AppKit
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextHostedChief
import CmuxNextRemote
import Foundation
import Observation
import os
import CmuxNextWakeups

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
    /// The app's main-thread scheduler (from the composition root): every server's event batches run on it.
    private let mainWork: MainWorkScheduler
    /// The app's notices (`AppServices.appEvents`): activation wakes the servers.
    private let appEvents: AppEvents
    private let call: Call
    /// The signed-in user's id, or nil when signed out (observed).
    private let signedInUser: @MainActor () -> String?
    private let paths: SSHPaths
    private let binary: URL?
    /// The app's own bundled `cmux` (overlay bridge and link reads).
    private let cli: URL?
    private let local: @MainActor () -> ServerReachPlan.LocalServer?
    /// This Mac's link (running or not) and its paired installs, or nil (no link): read off the main thread.
    private let linkPeers: @Sendable () async -> ServerReachPlan.LinkPeers?
    /// Where `cmux link init` writes the link (watched while `link show`
    /// fails, so a later init re-reads by event); nil watches nothing.
    private let linkSetupFile: String?
    private let makeWatcher: LocalServerSource.MakeWatcher
    private var linkWatchers: [any ServerFileWatching] = []
    private var watchedLinkFiles: [String] = []
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.server-reach")
    /// Sign-in and sign-out, the registry's records, the home daemon's identity: service observations
    /// (their side effects connect and close servers whether or not anything shows), and the activation notice.
    private var userWatch: ServiceObservation<String?>?
    private var recordsWatch: ServiceObservation<[SessionRecord]>?
    private var identityWatch: ServiceObservation<Bool>?
    private var activation: EventSubscription?
    /// The signed-in user the last sign-in change saw; nil before the first and while signed out.
    private var lastUser: String?
    private var reading: Task<Void, Never>?
    /// Counts stops: a read that a stop overtook applies nothing.
    private var epoch = 0
    /// Another read was asked for while one ran: run once more after it.
    private var readAgain = false
    /// Hosts removed in this run, so a stale registry echo does not bring them back.
    private var removed: Set<String> = []
    private(set) var lastPlan: ServerReachPlan?
    /// Set while an administrator turned remote hosts off: no server connects.
    private(set) var policyDisabled = false

    init(machines: MachineRegistry, mainWork: MainWorkScheduler, appEvents: AppEvents, call: @escaping Call,
         signedInUser: @escaping @MainActor () -> String?, paths: SSHPaths,
         binary: URL?, local: @escaping @MainActor () -> ServerReachPlan.LocalServer? = { nil },
         linkPeers: @escaping @Sendable () async -> ServerReachPlan.LinkPeers? = { nil }, cli: URL? = nil,
         linkSetupFile: String? = nil, makeWatcher: @escaping LocalServerSource.MakeWatcher = LocalServerSource.fileWatcher) {
        self.linkSetupFile = linkSetupFile
        self.makeWatcher = makeWatcher
        self.cli = cli
        self.machines = machines
        self.mainWork = mainWork
        self.appEvents = appEvents
        self.call = call
        self.signedInUser = signedInUser
        self.paths = paths
        self.binary = binary
        self.local = local
        self.linkPeers = linkPeers
    }

    /// Follows the account, the registry and the home daemon's identity (each applies its current value now), and
    /// the app's activation.
    func start() {
        let machines = machines, signedInUser = signedInUser
        lastUser = nil
        userWatch = ServiceObservation(.visible, owner: "ServerReach.user", on: mainWork) {
            signedInUser()
        } apply: { [weak self] user in
            self?.signedInUserChanged(user)
        }
        activation = appEvents.subscribe(NSApplication.didBecomeActiveNotification, owner: "ServerReach.activation") { [weak self] in
            self?.appBecameActive()
        }
        recordsWatch = ServiceObservation(.visible, owner: "ServerReach.records", on: mainWork) { () -> [SessionRecord] in
            let store = machines.local.store
            return store.personal.isLoaded && !store.isProvisional ? store.personal.sessions : []
        } apply: { [weak self] records in
            self?.restore(records)
        }
        // A server on this Mac connects only once the home daemon's identity
        // is known, so the admit check can refuse a route back to it.
        identityWatch = ServiceObservation(.visible, owner: "ServerReach.identity", on: mainWork) {
            machines.local.identity != nil
        } apply: { [weak self] known in
            guard known, let self, !self.policyDisabled else { return }
            for server in self.machines.servers where server.autoConnect { server.connect() }
        }
    }

    /// Servers belong to the account: any change of user closes them; a signed-in user's are restored and read.
    private func signedInUserChanged(_ user: String?) {
        if lastUser != nil, user != lastUser {
            closeAll()
        }
        lastUser = user
        if user != nil {
            restore(currentRecords())
            refresh()
        }
    }

    /// The app became active: read again and wake the servers set to connect.
    private func appBecameActive() {
        refresh()
        guard !policyDisabled else { return }
        for server in machines.servers where server.autoConnect { server.wake() }
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
        userWatch?.cancel()
        userWatch = nil
        recordsWatch?.cancel()
        recordsWatch = nil
        identityWatch?.cancel()
        identityWatch = nil
        activation?.cancel()
        activation = nil
        reading?.cancel()
        epoch &+= 1
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
        let mainWork = mainWork
        // The read runs off the main thread (`read()`); its end is one visible task.
        reading = Task { @concurrent [weak self] in
            await self?.read()
            mainWork.postFromAnyThread(.visible, owner: "ServerReach.readFinished") { [weak self] in self?.readFinished() }
        }
    }

    /// A read ended: runs the read asked for meanwhile.
    private func readFinished() {
        reading = nil
        if readAgain {
            readAgain = false
            refresh()
        }
    }

    /// One read and apply (`refresh` serializes these). A failed read changes nothing. Chrome's PostTaskAndReply
    /// (base/task/task_runner.h): the directory and the link are read off the main thread, the plan applies in one
    /// visible task, and the removed servers' home-session records are forgotten off main again.
    @concurrent nonisolated func read() async {
        guard let start = await readStart() else { return }
        let found: Reading
        do {
            found = try await fetch(start)
        } catch {
            start.logger.error("server reach read failed: \(String(describing: error), privacy: .public)")
            return
        }
        guard !Task.isCancelled else { return }
        let forgets = await start.mainWork.apply(.visible, owner: "ServerReach.apply") { [weak self] in
            self?.applyRead(found, start) ?? []
        }
        for forget in forgets { await forget.run(start.logger) }
    }

    /// The start of a read for the signed-in user; nil while signed out.
    private func readStart() -> ReadStart? {
        signedInUser().map { ReadStart(user: $0, epoch: epoch, mainWork: mainWork, linkPeers: linkPeers, logger: logger) }
    }

    /// A read's main part: the link's watches, the plan and its apply, unless a sign-out, an account switch or a
    /// stop overtook the read. Returns the removed servers' records to forget.
    private func applyRead(_ found: Reading, _ start: ReadStart) -> [Forget] {
        guard start.epoch == epoch, signedInUser() == start.user else { return [] }
        watchLink(found.link?.watchedFiles ?? [linkSetupFile].compactMap { $0 })
        let plan = ServerReachPlan.make(chiefs: found.chiefs, hosts: found.hosts, local: local(), link: found.link)
        lastPlan = plan
        for name in plan.unroutable { logger.error("server \(name, privacy: .public): no route to its chief session") }
        return apply(plan.desired)
    }

    /// What one read found, in values that leave the main thread: the directory as the signed-in user and this
    /// Mac's link.
    nonisolated struct Reading: Sendable {
        var chiefs: [CloudChief]
        var hosts: [PairedServer]
        var link: ServerReachPlan.LinkPeers?
    }

    /// One home-session record of a removed server, forgotten off the main thread.
    nonisolated struct Forget: Sendable {
        let home: DaemonConnection
        let sessionID: String

        func run(_ logger: Logger) async {
            do {
                _ = try await home.forgetSession(sessionID, force: true)
            } catch {
                logger.error("forget-session \(sessionID, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// What a read takes from the service when it starts: who it reads for, the stops before it, and its seams.
    nonisolated struct ReadStart: Sendable {
        let user: String
        let epoch: Int
        let mainWork: MainWorkScheduler
        let linkPeers: @Sendable () async -> ServerReachPlan.LinkPeers?
        let logger: Logger
    }

    /// The directory's pages and the link. The feed's calls are main-actor by their type (`CloudChiefs.Call`): each
    /// reply is parsed on its own turn into values that cross back here.
    @concurrent nonisolated private func fetch(_ start: ReadStart) async throws -> Reading {
        let chiefs = try await readChiefs()
        var hosts: [PairedServer] = []
        var cursor: String?
        for _ in 0..<20 {
            let page = try await readHosts(after: cursor)
            hosts += page.hosts
            guard let next = page.next, !next.isEmpty else { return Reading(chiefs: chiefs, hosts: hosts, link: await start.linkPeers()) }
            cursor = next
        }
        // A directory larger than the cap is a partial read: never act on it.
        throw ServerReachPlan.ReadError.tooManyHosts
    }

    private func readChiefs() async throws -> [CloudChief] {
        try ServerReachPlan.parseChiefs(try CloudPairingSource.okValue(try await call("v1/read", ["op": "chief.list", "params": [String: Any]()])))
    }

    /// One page of `team.hosts.list` and its next cursor.
    private func readHosts(after cursor: String?) async throws -> (hosts: [PairedServer], next: String?) {
        var params: [String: Any] = ["limit": 100]
        if let cursor { params["cursor"] = cursor }
        return try ServerReachPlan.parseHosts(try CloudPairingSource.okValue(try await call("v1/read", ["op": "team.hosts.list", "params": params])))
    }

    /// Adds the servers that should show and removes the rest; returns the removed servers' home-session records,
    /// which the caller forgets off main.
    func apply(_ desired: [ServerReach]) -> [Forget] {
        let change = ServerReachPlan.diff(shown: machines.servers.map(\.reach), desired: desired)
        for reach in change.add {
            removed.remove(reach.hostID)
            add(reach, connect: true)
        }
        let forgets = change.remove.compactMap { remove($0) }
        for reach in change.reroute { reroute(reach) }
        return forgets
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
        let mainWork = mainWork
        linkWatchers = files.map { file in
            let watcher = makeWatcher(URL(fileURLWithPath: file)) { [weak self] in
                // `cmux link` changed the pairing file: one automation task per file event; refresh coalesces reads.
                mainWork.postFromAnyThread(.automation, owner: "ServerReach.linkFile") { [weak self] in self?.refresh() }
            }
            watcher.start()
            return watcher
        }
    }

    /// Restores servers the registry holds that this run has not seen.
    func restore(_ records: [SessionRecord]) {
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
                                           localIdentity: { [machines] in machines.local.identity }, cli: cli,
                                           mainWork: mainWork, deadlines: machines.local.deadlines, appEvents: machines.local.appEvents)
        session.daemon.workTracker = machines.local.workTracker
        session.daemon.onPaneNotReady = machines.local.onPaneNotReady
        // The overlay ended: re-read the link (`link show` checks its pid
        // and socket), so a crashed link with a stale link.json falls back.
        session.onOverlayEnded = { [weak self] in self?.refresh() }
        machines.add(session)
        logger.info("server \(reach.name, privacy: .public) (\(reach.hostID, privacy: .public)) added")
        session.autoConnect = connect
        if policyDisabled || machines.isFeatureDisabled(.remoteHosts) {
            session.daemon.policyBlock.set(policyDisabled)
        } else if connect {
            session.connect()
        }
    }

    /// Closes the server's session and removes it; its registry record and personal organization leave the home
    /// session through the returned forget.
    private func remove(_ machineID: String) -> Forget? {
        guard let session = machines.removeServer(machineID) else { return nil }
        removed.insert(session.reach.hostID)
        // Forget only this server's own record: the one whose transport names
        // its host; the daemon's identity counts only when it is that record.
        let reported = session.daemon.identity?.sessionID
        let sessionID = recordID(for: session.reach) ?? reported.flatMap { id in
            machines.local.store.personal.session(id) == nil ? nil : id
        }
        session.close()
        logger.info("server \(session.reach.name, privacy: .public) removed")
        guard let sessionID, sessionID != machines.local.identity?.sessionID, machines.local.supports(DaemonCapability.profiles.rawValue), let home = machines.local.connection else { return nil }
        return Forget(home: home, sessionID: sessionID)
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
}
