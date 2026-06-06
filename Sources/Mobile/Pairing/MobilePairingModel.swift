import CMUXMobileCore
import Foundation
import Observation

/// Drives the in-app iOS pairing window: turns on the Mac-side pairing host,
/// mints a short-lived attach ticket, and exposes the QR payload plus a
/// human-readable fallback (host:port routes) for the view to render.
///
/// Opening the window auto-enables the pairing listener (writing the same
/// `UserDefaults` flag the Settings toggle uses), which is what triggers the
/// macOS Local Network permission prompt on first use.
@MainActor
@Observable
final class MobilePairingModel {
    /// The pairing window's render state.
    enum State: Equatable {
        /// Bringing the listener up and minting the first ticket.
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
        /// Reachable `host:port` routes for the manual-entry fallback.
        let routeLines: [String]
    }

    /// The current render state, observed by ``MobilePairingView``.
    private(set) var state: State = .preparing

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

    /// Enables the pairing host, waits for the listener to be ready, and mints
    /// a fresh attach ticket. Safe to call repeatedly (e.g. from a Refresh
    /// button); the latest result wins.
    func refresh() async {
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
                    routeLines: Self.routeLines(status.routes)
                )
            )
        } catch {
            state = .failed(String(describing: error))
        }
    }

    private func enablePairingHost() {
        UserDefaults.standard.set(true, forKey: MobileHostService.listeningEnabledDefaultsKey)
    }

    private static var macDisplayName: String {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }

    private static func routeLines(_ routes: [CmxAttachRoute]) -> [String] {
        routes.compactMap { route in
            if case let .hostPort(host, port) = route.endpoint {
                return "\(host):\(port)"
            }
            return nil
        }
    }
}
