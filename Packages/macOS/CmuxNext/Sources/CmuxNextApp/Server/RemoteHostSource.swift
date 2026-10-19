import AppKit
import CmuxNextDaemon
import CmuxNextRemote
import Foundation
import os

/// Remote hosts in the sidebar (plans/cmux-next/remote-hosts.md 9): the
/// bundled `cmux host list --json` names the machines on the user's private
/// network that run `cmux host serve` and admit this caller; each one joins
/// `MachineRegistry` as a server machine on the `tailnet` route (its daemon
/// connection runs `cmux host dial <name>`), shown as its own sidebar group.
///
/// Discovery, probing and admission are the CLI's (Rust); this type only runs
/// it and applies the list. It reads at launch, when the app becomes active and
/// when a sidebar opens, never on a timer. A host that leaves the list is
/// closed only when it is gone from the private network (see ``apply(_:)``); a failed
/// read (the private network is off, no CLI) changes nothing.
@MainActor
final class RemoteHostSource {
    /// One `cmux host list --json --all` read, or nil when the read failed.
    typealias List = @MainActor () async -> Listing?

    private let machines: MachineRegistry
    private let cli: URL?
    private let list: List
    private let paths: SSHPaths
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.remote-hosts")
    private var observers: [Task<Void, Never>] = []
    private var reading: Task<Void, Never>?
    /// Another read was asked for while one ran: run once more after it.
    private var readAgain = false
    /// Set while an administrator turned remote hosts off (`DisabledFeatures`).
    private(set) var policyDisabled = false
    /// The names of the last successful read (`remote.hosts` reports).
    private(set) var lastListed: [String]?

    init(machines: MachineRegistry, cli: URL?, paths: SSHPaths, list: @escaping List) {
        self.machines = machines
        self.cli = cli
        self.paths = paths
        self.list = list
    }

    /// The hosts this source shows (the paired servers share `machines.servers`).
    var hosts: [ServerMachineSession] { machines.servers.filter(\.reach.isTailnetHost) }

    func start() {
        guard observers.isEmpty else { return }
        observers.append(Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification) {
                self?.refresh()
            }
        })
        refresh()
    }

    func stop() {
        for observer in observers { observer.cancel() }
        observers.removeAll()
        reading?.cancel()
        reading = nil
        closeAll()
    }

    /// Turning remote hosts off closes every remote host; turning it on reads again.
    func applyPolicy(disabled: Bool) {
        guard disabled != policyDisabled else { return }
        policyDisabled = disabled
        if disabled {
            reading?.cancel()
            reading = nil
            closeAll()
        } else {
            refresh()
        }
    }

    /// Reads the host list once and applies it; a call during a read runs one more read after it.
    func refresh() {
        guard !policyDisabled, cli != nil else { return }
        guard reading == nil else {
            readAgain = true
            return
        }
        reading = Task { [weak self, list] in
            let listing = await list()
            guard let self, !Task.isCancelled else { return }
            reading = nil
            if let listing, !policyDisabled { apply(listing) }
            if readAgain {
                readAgain = false
                refresh()
            }
        }
    }

    /// Applies one `cmux host list --json --all` read:
    /// - a host that answered shows and connects;
    /// - a host this Mac knows (shown now, or recorded in the home session) that is on the
    ///   private network but did not answer (asleep, offline, not serving) stays shown as
    ///   unreachable with the reason, and does not dial until it answers again;
    /// - a shown host the list no longer names at all (gone from the private network, or no
    ///   longer one this account may use) closes. Its home registry record and personal
    ///   organization stay: a transient absence never forgets anything.
    func apply(_ listing: Listing) {
        var desired: [String: (reach: ServerReach, reason: String?)] = [:]
        for name in listing.hosts {
            guard let reach = Self.reach(name) else { continue }
            desired[reach.machineID] = (reach, nil)
        }
        let known = Set(hosts.map(\.machineID)).union(recordedHosts())
        for (name, reason) in listing.unavailable {
            guard let reach = Self.reach(name), desired[reach.machineID] == nil, known.contains(reach.machineID) else { continue }
            desired[reach.machineID] = (reach, reason)
        }
        lastListed = listing.hosts
        for session in hosts where desired[session.machineID] == nil {
            session.close()
            _ = machines.removeServer(session.machineID)
            logger.info("remote host \(session.name, privacy: .public) left the private network")
        }
        for (reach, reason) in desired.values.sorted(by: { $0.reach.name < $1.reach.name }) {
            if let session = machines.server(reach.machineID) {
                update(session, unavailable: reason, fresh: false)
            } else {
                add(reach, unavailable: reason)
            }
        }
    }

    /// One read of the list: the hosts that answered, and the other eligible peers with why.
    struct Listing: Equatable, Sendable {
        var hosts: [String]
        /// Name to reason (`offline`, `not serving`, `no answer`, `not_allowed`, `session_down`, ...).
        var unavailable: [String: String]
    }

    private static func reach(_ name: String) -> ServerReach? {
        try? ServerReach.tailnetHost(name: name)
    }

    /// The machine ids of remote hosts the home session has a record for (connected before).
    private func recordedHosts() -> Set<String> {
        let store = machines.local.store
        guard store.personal.isLoaded, !store.isProvisional else { return [] }
        return Set(store.personal.sessions.compactMap { record in
            record.transport.flatMap(SSHService.fields).flatMap(ServerReach.init(transportFields:))
                .flatMap { $0.isTailnetHost ? $0.machineID : nil }
        })
    }

    private func add(_ reach: ServerReach, unavailable reason: String?) {
        // No SSH binary: the tailnet route never uses the SSH carrier.
        let session = ServerMachineSession(reach: reach, binary: nil, paths: paths, environment: SSHService.environment,
                                           localIdentity: { [machines] in machines.local.identity }, cli: cli)
        session.daemon.workTracker = machines.local.workTracker
        machines.add(session)
        logger.info("remote host \(reach.name, privacy: .public) added")
        update(session, unavailable: reason, fresh: true)
    }

    /// A host that answers connects (once the home daemon's identity is known; ServerReachService
    /// connects every waiting server then, so the admit check can refuse a route back to this Mac).
    /// A host that does not answer keeps its section, unreachable with the list's reason, and does
    /// not dial.
    private func update(_ session: ServerMachineSession, unavailable reason: String?, fresh: Bool) {
        let was = session.unavailableReason
        session.unavailableReason = reason
        if reason != nil {
            if fresh || was == nil { session.disconnect() }
            // Not dialed on the home identity or app activation until a read lists it again.
            session.autoConnect = false
        } else if fresh || was != nil {
            session.connect()
        }
    }

    private func closeAll() {
        for session in hosts {
            session.close()
            _ = machines.removeServer(session.machineID)
        }
    }

    /// `cmux host list --json --all` through the bundled CLI: the hosts that answered the
    /// probe and the other eligible peers with why (offline ones included), except this
    /// machine; nil when the CLI is missing, fails (the private network is off) or prints
    /// something else.
    nonisolated static func readList(cli: URL?) async -> Listing? {
        guard let cli,
              let result = try? await ProcessRunner.run(executable: cli, arguments: ["host", "list", "--json", "--all"], environment: nil,
                                                        timeout: .seconds(15), clock: ContinuousClock()),
              result.status == 0 else { return nil }
        return parseList(result.stdout)
    }

    /// A `cmux host list --json --all` reply
    /// (`{"hosts":[{"name",…}],"not_hosts":[{"name","reason"}],"self":…}`); nil when the reply
    /// has no `hosts` array.
    nonisolated static func parseList(_ data: Data) -> Listing? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let hosts = object["hosts"] as? [Any] else { return nil }
        let me = (object["self"] as? String)?.lowercased()
        let keep = { (name: String) in !name.isEmpty && name.lowercased() != me }
        var unavailable: [String: String] = [:]
        for case let entry as [String: Any] in object["not_hosts"] as? [Any] ?? [] {
            guard let name = entry["name"] as? String, keep(name) else { continue }
            unavailable[name] = entry["reason"] as? String ?? "unreachable"
        }
        return Listing(hosts: hosts.compactMap { ($0 as? [String: Any])?["name"] as? String }.filter(keep),
                       unavailable: unavailable)
    }
}

extension RemoteHostSource {
    /// The app's source: the bundle's own `cmux` (never one found on PATH).
    static func app(services: AppServices) -> RemoteHostSource {
        let cli = bundledCLI()
        return RemoteHostSource(machines: services.machines, cli: cli,
                                paths: SSHPaths.standard(bundleID: services.environment.launch.bundleID),
                                list: { await RemoteHostSource.readList(cli: cli) })
    }

    /// `Contents/Resources/bin/cmux`, when it is there and executable.
    static func bundledCLI() -> URL? {
        let bundled: URL? = Bundle.main.resourceURL?.appendingPathComponent("bin/cmux")
        return bundled.flatMap { FileManager.default.isExecutableFile(atPath: $0.path) ? $0 : nil }
    }
}
