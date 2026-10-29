import CmuxBrowser
import CmuxSettings
import Foundation
import Security

/// Per-WebKit-delegate state for user-approved server-trust bypasses.
///
/// WebKit requires synchronous answers from `WKNavigationDelegate`, so this is
/// owned by one navigation delegate instead of a global actor or singleton.
/// That keeps bypass grants scoped to the lifetime of the relevant browser
/// surface while preserving the exact failed `URLRequest` for replay.
@MainActor
final class BrowserSSLTrustBypassState {
    private static let replayableWithoutBodyMethods: Set<String> = ["GET", "HEAD"]

    private enum ObservedServerTrust {
        case trust(SecTrust)
        case fingerprint(BrowserServerTrustFingerprint)
    }

    private var bypassedTrusts: Set<BrowserSSLTrustGrant> = []
    private var bypassedTrustOrder: [BrowserSSLTrustGrant] = []
    /// Trusts are kept unhashed: fingerprinting evaluates the trust, a
    /// synchronous trustd round trip on the main thread (#19726), so only the
    /// error page's bypass offer pays for it.
    private var observedTrusts: [BrowserSSLTrustScope: ObservedServerTrust] = [:]
    private var observedTrustOrder: [BrowserSSLTrustScope] = []
    private var pendingBypasses: [String: BrowserPendingSSLTrustBypass] = [:]
    private var pendingTokenOrder: [String] = []
    private let tokenLifetime: TimeInterval
    private let maximumPendingBypassCount: Int
    private let maximumRetainedRequestBodyBytes: Int
    private let now: () -> Date
    /// `DisableTLSTrustBypass` (MDM): while false, no bypass is offered,
    /// minted, consumed, or honored. Read per call so a profile pushed
    /// mid-session applies to the next navigation.
    private let isBypassAllowed: () -> Bool
    private let fingerprintServerTrust: (SecTrust) -> BrowserServerTrustFingerprint?

    init(
        tokenLifetime: TimeInterval = 24 * 60 * 60,
        maximumPendingBypassCount: Int = 32,
        maximumRetainedRequestBodyBytes: Int = 1_048_576,
        now: @escaping () -> Date = { Date.now },
        isBypassAllowed: @escaping () -> Bool = {
            !ManagedDevicePolicy().isEnforced(.disableTLSTrustBypass)
        },
        fingerprintServerTrust: @escaping (SecTrust) -> BrowserServerTrustFingerprint? = {
            BrowserServerTrustFingerprint(serverTrust: $0)
        }
    ) {
        self.isBypassAllowed = isBypassAllowed
        self.fingerprintServerTrust = fingerprintServerTrust
        self.tokenLifetime = tokenLifetime
        self.maximumPendingBypassCount = max(1, maximumPendingBypassCount)
        self.maximumRetainedRequestBodyBytes = max(0, maximumRetainedRequestBodyBytes)
        self.now = now
    }

    func recordObservedServerTrust(_ trust: SecTrust, for protectionSpace: URLProtectionSpace) {
        guard let scope = BrowserSSLTrustScope(protectionSpace: protectionSpace) else { return }
        recordObservedServerTrust(.trust(trust), for: scope)
    }

    func recordObservedServerTrustFingerprint(
        _ fingerprint: BrowserServerTrustFingerprint,
        for scope: BrowserSSLTrustScope
    ) {
        recordObservedServerTrust(.fingerprint(fingerprint), for: scope)
    }

    private func recordObservedServerTrust(_ observed: ObservedServerTrust, for scope: BrowserSSLTrustScope) {
        observedTrusts[scope] = observed
        observedTrustOrder.removeAll { $0 == scope }
        observedTrustOrder.append(scope)
        enforceObservedTrustLimit()
    }

    private func observedFingerprint(for scope: BrowserSSLTrustScope) -> BrowserServerTrustFingerprint? {
        switch observedTrusts[scope] {
        case .fingerprint(let fingerprint):
            return fingerprint
        case .trust(let trust):
            guard let fingerprint = fingerprintServerTrust(trust) else { return nil }
            observedTrusts[scope] = .fingerprint(fingerprint)
            return fingerprint
        case nil:
            return nil
        }
    }

    func isBypassed(protectionSpace: URLProtectionSpace, serverTrust: SecTrust) -> Bool {
        // Nearly every challenge has no grant; skip hashing the certificate.
        guard isBypassAllowed(),
              let scope = BrowserSSLTrustScope(protectionSpace: protectionSpace),
              bypassedTrusts.contains(where: { $0.scope == scope }),
              let fingerprint = fingerprintServerTrust(serverTrust) else {
            return false
        }
        return isBypassed(scope: scope, fingerprint: fingerprint)
    }

    func isBypassed(scope: BrowserSSLTrustScope, fingerprint: BrowserServerTrustFingerprint) -> Bool {
        guard isBypassAllowed() else { return false }
        return bypassedTrusts.contains(BrowserSSLTrustGrant(scope: scope, fingerprint: fingerprint))
    }

    func createPendingBypassAction(for request: URLRequest) -> URL? {
        guard isBypassAllowed() else { return nil }
        guard let url = request.url,
              let scope = BrowserSSLTrustScope(url: url),
              let fingerprint = observedFingerprint(for: scope),
              canRetainRequestForReplay(request) else {
            return nil
        }

        let token = UUID().uuidString
        let currentDate = now()
        purgeExpiredPendingBypasses(now: currentDate)
        pendingBypasses[token] = BrowserPendingSSLTrustBypass(
            grant: BrowserSSLTrustGrant(scope: scope, fingerprint: fingerprint),
            request: request,
            expiresAt: currentDate.addingTimeInterval(tokenLifetime)
        )
        pendingTokenOrder.append(token)
        enforcePendingBypassLimit()

        var components = URLComponents()
        components.scheme = "cmux-browser-action"
        components.host = "bypass-ssl"
        components.queryItems = [
            URLQueryItem(name: "token", value: token),
        ]
        return components.url
    }

    func beginObservingServerTrustForNavigation() {
        clearPendingBypasses()
        clearObservedServerTrusts()
    }

    func hasPendingBypassToken(_ token: String) -> Bool {
        guard isBypassAllowed() else { return false }
        purgeExpiredPendingBypasses(now: now())
        return pendingBypasses[token] != nil
    }

    func consumePendingBypassAction(_ actionURL: URL) -> URLRequest? {
        guard actionURL.scheme == "cmux-browser-action",
              actionURL.host == "bypass-ssl",
              let components = URLComponents(url: actionURL, resolvingAgainstBaseURL: false),
              let token = components.queryItems?.first(where: { $0.name == "token" })?.value else {
            return nil
        }
        return consumePendingBypassToken(token)
    }

    func consumePendingBypassToken(_ token: String) -> URLRequest? {
        guard isBypassAllowed() else { return nil }
        let currentDate = now()
        purgeExpiredPendingBypasses(now: currentDate)

        guard let pending = pendingBypasses.removeValue(forKey: token) else {
            return nil
        }

        pendingTokenOrder.removeAll { $0 == token }
        guard pending.expiresAt > currentDate else {
            return nil
        }
        bypassedTrusts.insert(pending.grant)
        bypassedTrustOrder.removeAll { $0 == pending.grant }
        bypassedTrustOrder.append(pending.grant)
        enforceBypassedTrustLimit()
        return pending.request
    }

    func clearPendingBypasses() {
        pendingBypasses.removeAll()
        pendingTokenOrder.removeAll()
    }

    func clearAllTrustState() {
        clearPendingBypasses()
        clearObservedServerTrusts()
        bypassedTrusts.removeAll()
        bypassedTrustOrder.removeAll()
    }

    private func clearObservedServerTrusts() {
        observedTrusts.removeAll()
        observedTrustOrder.removeAll()
    }

    private func purgeExpiredPendingBypasses(now currentDate: Date) {
        pendingBypasses = pendingBypasses.filter { $0.value.expiresAt > currentDate }
        pendingTokenOrder.removeAll { pendingBypasses[$0] == nil }
    }

    private func enforcePendingBypassLimit() {
        while pendingTokenOrder.count > maximumPendingBypassCount {
            let token = pendingTokenOrder.removeFirst()
            pendingBypasses.removeValue(forKey: token)
        }
    }

    private func enforceObservedTrustLimit() {
        while observedTrustOrder.count > maximumPendingBypassCount {
            let scope = observedTrustOrder.removeFirst()
            observedTrusts.removeValue(forKey: scope)
        }
    }

    private func enforceBypassedTrustLimit() {
        while bypassedTrustOrder.count > maximumPendingBypassCount {
            let grant = bypassedTrustOrder.removeFirst()
            bypassedTrusts.remove(grant)
        }
    }

    func canRetainRequestForReplay(_ request: URLRequest) -> Bool {
        guard request.httpBodyStream == nil else {
            return false
        }
        let method = request.httpMethod?.uppercased() ?? "GET"
        guard let body = request.httpBody else {
            return Self.replayableWithoutBodyMethods.contains(method)
        }
        return body.count <= maximumRetainedRequestBodyBytes
    }
}
