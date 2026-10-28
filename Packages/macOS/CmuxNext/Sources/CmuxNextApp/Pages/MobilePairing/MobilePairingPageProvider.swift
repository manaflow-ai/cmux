import CmuxNextCompat
import CMUXMobileCore
import CmuxNextMobile
import CmuxNextPages
import CmuxNextPhoneAccess
import CmuxNextSettings
import CmuxNextWakeups
import Foundation

/// Serves the Mobile Pairing page's `cmux.mobilePairing.*` ops from the
/// phone host (``MobileHostService``), the Cloud account and Settings >
/// Accounts > Phone Access:
/// - `status` → the page's `MobilePairingStatus` (state, account, this
///   Mac's name, phone access, phones connected, and the QR code once ready);
/// - `setAllowed {on}` → writes `phone.allowConnections`, only right after the
///   person's own click or key in the page (the host's record, not the page's);
/// - stream `changes` → one empty event whenever any of those may have changed.
@MainActor
final class MobilePairingPageProvider: PageProvider {
    static let statusOp = "cmux.mobilePairing.status"
    static let setAllowedOp = "cmux.mobilePairing.setAllowed"
    static let changesStream = "cmux.mobilePairing.changes"
    /// How long a shown attach URL lasts; the page asks for a new one when it expires.
    static let ticketLifetime: TimeInterval = 600

    private weak var services: AppServices?
    private let qr = PairingQRCode()
    /// The code shown now, for the listener that minted it.
    private var ticket: (host: ObjectIdentifier, url: String, image: String, expiresAt: Date)?

    init(services: AppServices) {
        self.services = services
    }

    /// The person's own steps from the page (Phone Access on or off) that have not answered.
    private(set) var personCallsInFlight = 0

    func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        guard let services else { throw PageError.closed }
        switch op {
        case Self.statusOp:
            return await status(services)
        case Self.setAllowedOp:
            guard context.userGesture || context.isConfirmedUser else {
                throw PageError(code: PageNativeOp.userOnlyCode, message: RefusalStrings.personOnlyFromPage)
            }
            guard let on = params["on"]?.boolValue else { throw PageError.invalidParams("on is required") }
            guard let settings = services.settings else {
                throw PageError(code: "cmux.mobilePairing.unavailable", message: MobilePairingStrings.settingsNotLoaded, retryable: true)
            }
            personCallsInFlight += 1
            defer { personCallsInFlight -= 1 }
            try await settings.setSetting(at: SessionSettings.allowConnectionsPath, to: .bool(on), by: .user)
            return .object([:])
        default:
            throw PageError.unknownOp(op)
        }
    }

    func subscribe(_ stream: String, filter: JSONValue, context: PageCallContext,
                   onEvent: @escaping @MainActor (JSONValue) -> Void) async throws -> PageSubscription {
        guard stream == Self.changesStream else { throw PageError.unknownOp(stream) }
        guard let services else { throw PageError.closed }
        // The page's router holds events while the page is hidden: a service observation, one
        // flush per frame. The first value is the state the page reads with `status` (applied in
        // `init`, before `subscribed` is set); only changes are events.
        let subscribed = PageStreamStart()
        let observation = ServiceObservation(.visible, owner: "mobile-pairing.changes", on: services.mainWork) { [weak services] in
            services.map(Self.fingerprint) ?? ""
        } apply: { _ in
            if subscribed.isDone { onEvent(.object([:])) }
        }
        subscribed.finish()
        // Each event is an empty "status changed" signal the page answers with one `status` read:
        // the newest one says all the dropped ones did.
        return PageSubscription(frozenDelivery: .latest) { observation.cancel() }
    }

    /// Everything `status` reads that can change while the page is open.
    private static func fingerprint(_ services: AppServices) -> String {
        let status = services.mobile.status
        return [String(services.cloud.isSignedIn), services.cloud.auth.user?.id ?? "",
                String(services.settings?.snapshot.sessions.allowsPhone ?? false),
                String(describing: status.phase), String(status.connectedPhones)].joined(separator: "|")
    }

    private func status(_ services: AppServices) async -> JSONValue {
        let cloud = services.cloud
        let signedIn = cloud.isSignedIn
        let allowed = services.settings?.snapshot.sessions.allowsPhone ?? false
        let state = MobilePairingState.resolve(signedIn: signedIn, allowed: allowed, phase: services.mobile.status.phase)
        var reply: [String: JSONValue] = [
            "state": .string(state.wireName),
            "macName": .string(await MacName().displayName()),
            "allowed": .bool(allowed),
            "connectedPhones": JSONValue(services.mobile.status.connectedPhones),
        ]
        if signedIn, let account = cloud.auth.user?.primaryEmail ?? cloud.auth.user?.displayName {
            reply["account"] = .string(account)
        }
        if case .failed(let reason) = state { reply["failure"] = .string(reason) }
        if state == .ready, let code = await currentTicket(services) {
            reply["qr"] = ["url": .string(code.url), "image": .string(code.image),
                           "expiresAt": .number((code.expiresAt.timeIntervalSince1970 * 1000).rounded())]
        }
        return .object(reply)
    }

    /// The attach URL and its QR code for the running listener: reused until a
    /// minute before it expires. Nil when this build has no iPhone app to address
    /// (no pairing URL scheme) or the listener has no relay yet.
    private func currentTicket(_ services: AppServices) async -> (url: String, image: String, expiresAt: Date)? {
        guard let host = services.mobile.host else { return nil }
        let id = ObjectIdentifier(host)
        let now = Date()
        if let ticket, ticket.host == id, ticket.expiresAt.timeIntervalSince(now) > 60 {
            return (ticket.url, ticket.image, ticket.expiresAt)
        }
        guard let scheme = AppControl.pairingScheme(tag: services.environment.launch.tag),
              let payload = try? await host.attachTicket(ttl: Self.ticketLifetime, target: .physicalDevice, scheme: scheme),
              let image = qr.pngDataURL(for: payload.attachURL) else { return nil }
        let expiresAt = payload.ticket.expiresAt ?? now.addingTimeInterval(Self.ticketLifetime)
        ticket = (id, payload.attachURL, image, expiresAt)
        return (payload.attachURL, image, expiresAt)
    }
}
