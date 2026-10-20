import AppKit
import CmuxNextDaemon
import CmuxNextRemote
public import Foundation
import os

/// Remote hosts in the sidebar (plans/cmux-next/remote-hosts.md 9): the
/// bundled `cmux host list --json` names the machines on the user's private
/// network that run `cmux host serve` and admit this caller; each one joins the
/// ``RemoteHostRegistry`` (the App's `MachineRegistry`) as a server machine on the
/// `tailnet` route (its daemon connection runs `cmux host dial <name>`), shown as
/// its own sidebar group.
///
/// Discovery, probing and admission are the CLI's (Rust); this type only runs
/// it and applies the list. It reads at launch, when the app becomes active and
/// when a sidebar opens, never on a timer. A host that leaves the list is
/// closed only when it is gone from the private network (see ``apply(_:)``); a failed
/// read (the private network is off, no CLI) changes nothing.
@MainActor
public final class RemoteHostSource {
    /// One `cmux host list --json --all` read, or nil when the read failed.
    public typealias List = @MainActor () async -> RemoteHostList?

    private let registry: any RemoteHostRegistry
    private let cli: URL?
    private let list: List
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.remote-hosts")
    private var observers: [Task<Void, Never>] = []
    private var reading: Task<Void, Never>?
    /// Another read was asked for while one ran: run once more after it.
    private var readAgain = false
    /// Set while an administrator turned remote hosts off (`DisabledFeatures`).
    public private(set) var policyDisabled = false
    /// The names of the last successful read (`remote.hosts` reports).
    public private(set) var lastListed: [String]?

    public init(registry: any RemoteHostRegistry, cli: URL?, list: @escaping List) {
        self.registry = registry
        self.cli = cli
        self.list = list
    }

    /// The source for the bundle's own `cmux` (never one found on PATH).
    public static func bundled(registry: any RemoteHostRegistry) -> RemoteHostSource {
        let cli = RemoteHostList.bundledCLI()
        return RemoteHostSource(registry: registry, cli: cli, list: { await RemoteHostList.read(cli: cli) })
    }

    /// The header tooltip of a remote host that is not connected (``RemoteHostStrings/dialFailure(_:)``).
    public nonisolated static func dialFailure(_ reason: String) -> String { RemoteHostStrings.dialFailure(reason) }

    /// The hosts this source shows.
    private var hosts: [any RemoteHostSession] { registry.remoteHosts }

    public func start() {
        guard observers.isEmpty else { return }
        observers.append(Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification) {
                self?.refresh()
            }
        })
        refresh()
    }

    public func stop() {
        for observer in observers { observer.cancel() }
        observers.removeAll()
        reading?.cancel()
        reading = nil
        closeAll()
    }

    /// Turning remote hosts off closes every remote host; turning it on reads again.
    public func applyPolicy(disabled: Bool) {
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
    public func refresh() {
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
    public func apply(_ listing: RemoteHostList) {
        var desired: [String: (reach: ServerReach, reason: String?)] = [:]
        for name in listing.hosts {
            guard let reach = Self.reach(name) else { continue }
            desired[reach.machineID] = (reach, nil)
        }
        let known = Set(hosts.map(\.machineID)).union(registry.recordedRemoteHostIDs())
        for (name, reason) in listing.unavailable {
            guard let reach = Self.reach(name), desired[reach.machineID] == nil, known.contains(reach.machineID) else { continue }
            desired[reach.machineID] = (reach, reason)
        }
        lastListed = listing.hosts
        for session in hosts where desired[session.machineID] == nil {
            session.close()
            registry.removeRemoteHost(session.machineID)
            logger.info("remote host \(session.name, privacy: .public) left the private network")
        }
        for (reach, reason) in desired.values.sorted(by: { $0.reach.name < $1.reach.name }) {
            if let session = registry.remoteHost(reach.machineID) {
                update(session, unavailable: reason, fresh: false)
            } else {
                add(reach, unavailable: reason)
            }
        }
    }

    private static func reach(_ name: String) -> ServerReach? {
        try? ServerReach.tailnetHost(name: name)
    }

    private func add(_ reach: ServerReach, unavailable reason: String?) {
        let session = registry.addRemoteHost(reach, cli: cli)
        logger.info("remote host \(reach.name, privacy: .public) added")
        update(session, unavailable: reason, fresh: true)
    }

    /// A host that answers connects (once the home daemon's identity is known; ServerReachService
    /// connects every waiting server then, so the admit check can refuse a route back to this Mac).
    /// A host that does not answer keeps its section, unreachable with the list's reason, and does
    /// not dial.
    private func update(_ session: any RemoteHostSession, unavailable reason: String?, fresh: Bool) {
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
            registry.removeRemoteHost(session.machineID)
        }
    }
}
