import AppKit
import CmuxNextCompat
import CmuxNextDaemon
public import CmuxNextDaemonService
public import CmuxNextRemote
public import CmuxNextSettings
public import Foundation
public import Observation

/// Settings > Accounts > This Mac on Your Tailnet (Labs, `labs.previewFeatures`): the local
/// daemon's own tailnet node (`tailnet-v1`). It follows `tailnet.state` on the app's own control
/// connection while the card is enabled, once per connection; a daemon without the node refuses
/// the stream and the card shows "unavailable". Pair mints a single-use
/// `client` ticket (#23297) for this Mac's tailnet address.
@MainActor @Observable
public final class TailnetNodeService {
    /// The state shown by the Settings card.
    public let model: TailnetNodeModel
    @ObservationIgnored private let daemon: DaemonService
    @ObservationIgnored private let follower: TailnetStateFollower
    @ObservationIgnored private let qr: (String) -> String?

    /// Where the access choice will be kept once the node reads it (nothing writes it yet).
    static let accessKey = "tailnet.access"

    /// Composes the daemon-backed card with the app's defaults and QR renderer.
    public init(daemon: DaemonService, cli: HostCLI?, defaults: UserDefaults, qr: @escaping (String) -> String?) {
        self.daemon = daemon
        self.qr = qr
        model = TailnetNodeModel(services: TailnetNodeServices(
            loginStart: {
                guard let connection = daemon.connection else { throw DaemonError.notConnected }
                return try await TailnetNodeClient(connection).loginStart(as: TailnetNodeState.self)
            },
            logout: {
                guard let connection = daemon.connection else { throw DaemonError.notConnected }
                return try await TailnetNodeClient(connection).logout(as: TailnetNodeState.self)
            },
            openURL: { url in URL(string: url).map { NSWorkspace.shared.openInBackground($0) } },
            mintTicket: { address in
                guard let cli else { throw DaemonError.binaryNotFound(searched: []) }
                return try await cli.clientTicket(url: Self.redeemURL(address), label: "tailnet pair")
            },
            // main-actor-ok: one three-field value under 1 KB, read once when the card is made
            loadAccess: { defaults.data(forKey: Self.accessKey).flatMap { try? JSONDecoder().decode(TailnetAccess.self, from: $0) } }))
        follower = TailnetStateFollower(model: model)
    }

    /// `wss://<name>` for `https://<name>`: where the other Mac redeems the ticket.
    nonisolated static func redeemURL(_ address: String) -> String {
        "wss://" + address.dropFirst("https://".count)
    }

    /// The card in the Settings host lists, null while Labs is off. Reading it while enabled starts
    /// following the node (once per daemon connection; the follow ends with the connection).
    public func pageJSON(enabled: Bool) -> CmuxNextSettings.JSONValue {
        guard enabled else {
            stopFollowing()
            return .null
        }
        startFollowing()
        return TailnetNodePage.json(model: model, qr: qr)
    }

    /// Labs turned off: the `tailnet.state` read ends (its stream is cancelled on the daemon), and
    /// the next enable reads again.
    public func stopFollowing() {
        follower.stop()
        model.markUnavailable()
    }

    private func startFollowing() {
        guard let connection = daemon.connection else {
            follower.stop()
            return model.markUnavailable()
        }
        follower.follow(key: ObjectIdentifier(connection)) {
            try await TailnetNodeClient(connection).states(as: TailnetNodeState.self)
        }
    }
}
