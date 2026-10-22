import AppKit
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextRemote
import CmuxNextServer
import CmuxNextSettings
import Foundation
import Observation

/// Settings > Accounts > This Mac on Your Tailnet (Labs, `labs.previewFeatures`): the local
/// daemon's own tailnet node (`tailnet-v1`). It follows `tailnet.state` on the app's own control
/// connection while the card is enabled, once per connection; a daemon without the node refuses
/// the stream and the card shows "unavailable". Pair mints a single-use
/// `client` ticket (#23297) for this Mac's tailnet address.
@MainActor @Observable
final class TailnetNodeService {
    let model: TailnetNodeModel
    @ObservationIgnored private let daemon: DaemonService
    @ObservationIgnored private var follow: Task<Void, Never>?
    /// The connection the running (or last) follow read: a new connection is followed again.
    @ObservationIgnored private var followed: ObjectIdentifier?
    @ObservationIgnored private let qr = PairingQRCode()

    /// Where the access choice is kept until the node reads it from the daemon (UserDefaults).
    static let accessKey = "tailnet.access"

    init(daemon: DaemonService, defaults: UserDefaults = .standard) {
        self.daemon = daemon
        let cli = (try? DaemonLauncher.resolveBinary(bundle: .main, environment: ProcessInfo.processInfo.environment))
            .map { HostCLI(binary: $0, environment: SSHService.environment) }
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
            loadAccess: { defaults.data(forKey: Self.accessKey).flatMap { try? JSONDecoder().decode(TailnetAccess.self, from: $0) } },
            saveAccess: { access in (try? JSONEncoder().encode(access)).map { defaults.set($0, forKey: Self.accessKey) } }))
    }

    /// `wss://<name>` for `https://<name>`: where the other Mac redeems the ticket.
    nonisolated static func redeemURL(_ address: String) -> String {
        "wss://" + address.dropFirst("https://".count)
    }

    /// The card in the Settings host lists, null while Labs is off. Reading it while enabled starts
    /// following the node (once per daemon connection; the follow ends with the connection).
    func pageJSON(enabled: Bool) -> CmuxNextSettings.JSONValue {
        guard enabled else { return .null }
        startFollowing()
        return TailnetNodePage.json(model: model, qr: { [qr] in qr.pngDataURL(for: $0) })
    }

    private func startFollowing() {
        guard let connection = daemon.connection else { return model.markUnavailable() }
        let id = ObjectIdentifier(connection)
        guard followed != id else { return }
        followed = id
        follow?.cancel()
        // task-owner: one tailnet.state read per daemon connection; cancelled by the next or ends with the stream
        follow = Task { [weak self, model] in
            do {
                for await state in try await TailnetNodeClient(connection).states(as: TailnetNodeState.self) {
                    model.apply(state)
                }
            } catch {}
            guard !Task.isCancelled else { return }
            model.markUnavailable()
            // The stream ended (gap, restart): read again on the next host-lists read.
            if self?.followed == id { self?.followed = nil }
        }
    }
}
