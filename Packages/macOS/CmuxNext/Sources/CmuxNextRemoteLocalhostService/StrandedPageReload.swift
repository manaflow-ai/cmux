import CmuxNextCompat
public import CmuxNextDaemon
public import Foundation
import CmuxNextRemoteLocalhost

/// Loads again, when a machine connects again, its localhost pages that showed "not connected"
/// (#25595). A tab of a Cloud or SSH workspace on `localhost:3000` that loaded while the machine's
/// link was down (asleep, offline, the machine still booting) got the proxy's error page, and
/// nothing loaded it once the link was back: the person had to find the tab and reload it.
///
/// Only pages the proxy answered "not connected" reload (``RemoteLocalhostService/takeStranded(of:)``):
/// a page that loaded, or one whose port refused, stays as it is. Observation only; nothing polls.
@MainActor
public final class StrandedPageReload {
    private let localhost: RemoteLocalhostService
    private let machines: any RemoteLocalhostMachines
    private let reload: @MainActor (_ machineKey: String, _ addresses: Set<String>) -> Void
    /// The connection epoch each machine was last checked at.
    private var epochs: [ObjectIdentifier: Int] = [:]
    private var task: Task<Void, Never>?

    /// - Parameter reload: Loads again the pages of machine store `machineKey` whose URL's address
    ///   is one of `addresses` (``matches(_:addresses:)``).
    public init(localhost: RemoteLocalhostService, machines: any RemoteLocalhostMachines,
                reload: @escaping @MainActor (_ machineKey: String, _ addresses: Set<String>) -> Void) {
        self.localhost = localhost
        self.machines = machines
        self.reload = reload
    }

    /// Follows every machine's connection for the life of the app.
    public func start() {
        guard task == nil else { return }
        let machines = machines
        // task-owner: the app-lifetime reconnect watch
        task = Task { [weak self] in
            for await _ in ObservationStream({ machines.daemons.map(\.store.connectionState) }) {
                self?.connectionsChanged()
            }
        }
    }

    /// Each remote machine connected at a new epoch: its stranded pages load again.
    func connectionsChanged() {
        for daemon in machines.daemons where !daemon.isLocal {
            guard case .connected = daemon.store.connectionState else { continue }
            let id = ObjectIdentifier(daemon), epoch = daemon.store.connectionEpoch
            guard epochs[id] != epoch else { continue }
            epochs[id] = epoch
            guard let stranded = localhost.takeStranded(of: daemon), !stranded.addresses.isEmpty else { continue }
            reload(stranded.machineKey, stranded.addresses)
        }
    }

    /// Whether page `url` is one of `addresses` (``RemoteLocalhostProxy/address(host:port:)``).
    public nonisolated static func matches(_ url: URL, addresses: Set<String>) -> Bool {
        guard let host = url.host(percentEncoded: false), !host.isEmpty else { return false }
        let port = url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80)
        guard let port = UInt16(exactly: port) else { return false }
        return addresses.contains(RemoteLocalhostProxy.address(host: host, port: port))
    }
}
