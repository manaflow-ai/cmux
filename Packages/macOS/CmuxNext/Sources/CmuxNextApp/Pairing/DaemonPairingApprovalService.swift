import AppKit
import CmuxNextDaemon
import CmuxNextDesign

/// The app's side of WebSocket pairing (cmux-tui spec/transports.md "Authentication and
/// Pairing"): a browser tab (or another host) asks the local daemon to pair, the daemon announces
/// `pairing-requested` with a six-digit code to its trusted Unix subscribers, and this service shows
/// one dialog with the code and the peer. Approve admits that browser (the daemon answers it with
/// a reconnect credential); Deny, Escape and every dismissal refuse. `pairing-resolved` (another
/// surface answered, or the request expired) closes the dialog. Approve has no key: a Return typed
/// as the dialog opens must never admit a client. Automation may not press it (the identifier).
@MainActor
final class DaemonPairingApprovalService {
    private weak var services: AppServices?
    private var sideEvents: UInt64?
    /// Open dialogs by daemon pairing request id.
    private var dialogs: [UInt64: Int] = [:]
    private let center: CmuxDialogCenter

    init(services: AppServices, center: CmuxDialogCenter = .shared) {
        self.services = services
        self.center = center
    }

    func start() {
        guard sideEvents == nil, let store = services?.daemon.store else { return }
        sideEvents = store.sideEvents.subscribe { [weak self] event in self?.handle(event) }
    }

    func stop() {
        if let sideEvents { services?.daemon.store.sideEvents.unsubscribe(sideEvents) }
        sideEvents = nil
        for id in dialogs.values { _ = center.dismiss(id) }
        dialogs.removeAll()
    }

    private func handle(_ event: DaemonEvent) {
        guard case .unknown(let name, let payload) = event,
              let request = payload["request_id"]?.stringValue.flatMap({ UInt64($0) }) else { return }
        switch name {
        case "pairing-requested":
            guard dialogs[request] == nil, let code = payload["code"]?.stringValue else { return }
            let peer = payload["peer"]?.stringValue ?? ""
            let scope: CmuxDialogScope = services?.windows.active?.window.map { .window($0) } ?? .app
            dialogs[request] = center.present(DaemonPairingStrings.spec(code: code, peer: peer), in: scope) { [weak self] answer in
                self?.answer(request, approve: answer.button == DaemonPairingStrings.approveID)
            }
        case "pairing-resolved":
            if let id = dialogs.removeValue(forKey: request) { _ = center.dismiss(id) }
        default:
            return
        }
    }

    private func answer(_ request: UInt64, approve: Bool) {
        // A dialog closed by `pairing-resolved` was already removed: nothing to answer.
        guard dialogs.removeValue(forKey: request) != nil, let daemon = services?.daemon, daemon.connection != nil else { return }
        // The daemon's command path (its ticket, off main): the daemon refuses a stale request on its own.
        daemon.send("pairing.respond") { connection in _ = try await connection.request(PairingResponseRequest(request: request, approve: approve)) }
    }
}
