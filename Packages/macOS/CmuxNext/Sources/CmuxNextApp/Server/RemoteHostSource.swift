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
/// closed; a failed read (the private network is off, no CLI) changes nothing,
/// so a host that is down shows as unreachable with the dial's reason.
@MainActor
final class RemoteHostSource {
    /// One `cmux host list --json` read: the listed host names, or nil when the read failed.
    typealias List = @MainActor () async -> [String]?

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
            let names = await list()
            guard let self, !Task.isCancelled else { return }
            reading = nil
            if let names, !policyDisabled { apply(names) }
            if readAgain {
                readAgain = false
                refresh()
            }
        }
    }

    /// Adds the listed hosts that are not shown and closes the shown ones that are not listed.
    func apply(_ names: [String]) {
        var desired: [String: ServerReach] = [:]
        for name in names {
            guard let reach = try? ServerReach.tailnetHost(name: name) else {
                logger.error("remote host \(name, privacy: .public): not a host name")
                continue
            }
            desired[reach.machineID] = reach
        }
        lastListed = names
        for session in hosts where desired[session.machineID] == nil {
            session.close()
            _ = machines.removeServer(session.machineID)
            logger.info("remote host \(session.name, privacy: .public) left the list")
        }
        for reach in desired.values.sorted(by: { $0.name < $1.name }) where machines.server(reach.machineID) == nil {
            add(reach)
        }
    }

    private func add(_ reach: ServerReach) {
        // No SSH binary: the tailnet route never uses the SSH carrier.
        let session = ServerMachineSession(reach: reach, binary: nil, paths: paths, environment: SSHService.environment,
                                           localIdentity: { [machines] in machines.local.identity }, cli: cli)
        session.daemon.workTracker = machines.local.workTracker
        machines.add(session)
        logger.info("remote host \(reach.name, privacy: .public) added")
        // Connects once the home daemon's identity is known (ServerReachService
        // connects every waiting server then), so the admit check can refuse
        // a route back to this Mac.
        session.connect()
    }

    private func closeAll() {
        for session in hosts {
            session.close()
            _ = machines.removeServer(session.machineID)
        }
    }

    /// `cmux host list --json` through the bundled CLI: the names of the hosts
    /// that answered the probe, except this machine; nil when the CLI is missing,
    /// fails (the private network is off) or prints something else.
    nonisolated static func readList(cli: URL?) async -> [String]? {
        guard let cli,
              let result = try? await ProcessRunner.run(executable: cli, arguments: ["host", "list", "--json"], environment: nil,
                                                        timeout: .seconds(15), clock: ContinuousClock()),
              result.status == 0 else { return nil }
        return parseList(result.stdout)
    }

    /// The host names of a `cmux host list --json` reply (`{"hosts":[{"name",…}],"self":…}`);
    /// nil when the reply has no `hosts` array.
    nonisolated static func parseList(_ data: Data) -> [String]? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let hosts = object["hosts"] as? [Any] else { return nil }
        let me = (object["self"] as? String)?.lowercased()
        return hosts.compactMap { ($0 as? [String: Any])?["name"] as? String }.filter { !$0.isEmpty && $0.lowercased() != me }
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
