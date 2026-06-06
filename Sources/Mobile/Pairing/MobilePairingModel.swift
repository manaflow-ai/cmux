import CMUXAuthCore
import CMUXMobileCore
import Foundation
import Observation

/// Drives the in-app iOS pairing window. Gates pairing on the Mac being signed
/// in (authorization is a Stack same-account check), then turns on the
/// pairing host, mints a short-lived attach ticket, and exposes the QR payload
/// plus Tailscale reachability for the view.
///
/// Opening the window does not touch the listener until the user is signed in.
/// Once signed in, enabling the listener writes the same `UserDefaults` flag the
/// Settings toggle uses, which is what triggers the macOS Local Network
/// permission prompt on first use.
@MainActor
@Observable
final class MobilePairingModel {
    /// The pairing window's render state.
    enum State: Equatable {
        /// Resolving auth/listener state before anything is shown.
        case loading
        /// The Mac is not signed in; pairing can't be authorized yet.
        case signedOut
        /// Signed in; bringing the listener up and minting the first ticket.
        case preparing
        /// A ticket is ready to display.
        case ready(Ready)
        /// The listener could not be started or no ticket could be minted.
        case failed(String)
    }

    /// A minted ticket ready for display.
    struct Ready: Equatable {
        /// The `cmux-ios://attach?...` URL encoded into the QR code.
        let attachURL: String
        /// The Mac's display name, shown above the code.
        let macName: String
        /// Reachable Tailscale `host:port` routes. Empty when Tailscale is not
        /// detected, in which case a real iPhone cannot reach this Mac.
        let tailscaleLines: [String]

        /// Whether at least one Tailscale route resolved.
        var reachableViaTailscale: Bool { !tailscaleLines.isEmpty }
    }

    /// The current render state, observed by ``MobilePairingView``.
    private(set) var state: State = .loading
    /// The signed-in account email, shown in the checklist. `nil` when signed out.
    private(set) var signedInEmail: String?

    private let host: MobileHostService
    private let ticketTTL: TimeInterval

    /// Creates a pairing model.
    ///
    /// - Parameters:
    ///   - host: The Mac-side pairing host service. Defaults to the shared instance.
    ///   - ticketTTL: Attach-ticket lifetime in seconds. Defaults to 600.
    init(host: MobileHostService = .shared, ticketTTL: TimeInterval = 600) {
        self.host = host
        self.ticketTTL = ticketTTL
    }

    /// Re-evaluates sign-in state and, when signed in, brings the listener up
    /// and mints a fresh attach ticket. Safe to call repeatedly (Refresh button).
    func refresh() async {
        state = .loading
        await AuthManager.shared.awaitBootstrapped()
        guard AuthManager.shared.isAuthenticated else {
            signedInEmail = nil
            state = .signedOut
            return
        }
        signedInEmail = AuthManager.shared.currentUser?.primaryEmail
        state = .preparing
        enablePairingHost()
        let status = await host.ensureListeningAndReady()
        guard status.isRunning else {
            state = .failed(
                status.lastErrorDescription
                    ?? String(
                        localized: "mobile.pairing.error.listenerOffline",
                        defaultValue: "Could not start the pairing listener on this Mac."
                    )
            )
            return
        }
        do {
            let payload = try await host.createAttachTicket(
                workspaceID: "",
                terminalID: nil,
                ttl: ticketTTL
            )
            guard let attachURL = payload["attach_url"] as? String, !attachURL.isEmpty else {
                state = .failed(
                    String(
                        localized: "mobile.pairing.error.noTicket",
                        defaultValue: "Could not generate a pairing code. Try again."
                    )
                )
                return
            }
            state = .ready(
                Ready(
                    attachURL: attachURL,
                    macName: Self.macDisplayName,
                    tailscaleLines: Self.tailscaleLines(status.routes)
                )
            )
        } catch {
            state = .failed(String(describing: error))
        }
    }

    /// Launches the account sign-in flow and, on success, prepares a code.
    func signIn() async {
        state = .loading
        let signedIn = await AuthManager.shared.beginSignInAndAwait(timeout: 180)
        if signedIn {
            await refresh()
        } else {
            signedInEmail = nil
            state = .signedOut
        }
    }

    private func enablePairingHost() {
        UserDefaults.standard.set(true, forKey: MobileHostService.listeningEnabledDefaultsKey)
    }

    private static var macDisplayName: String {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }

    private static func tailscaleLines(_ routes: [CmxAttachRoute]) -> [String] {
        routes.compactMap { route in
            guard route.kind == .tailscale,
                  case let .hostPort(host, port) = route.endpoint else {
                return nil
            }
            return "\(host):\(port)"
        }
    }
}
