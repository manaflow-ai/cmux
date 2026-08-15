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

    private var bypassedTrusts: Set<BrowserSSLTrustGrant> = []
    private var bypassedTrustOrder: [BrowserSSLTrustGrant] = []
    private var observedFingerprints: [BrowserSSLTrustScope: BrowserServerTrustFingerprint] = [:]
    private var observedFingerprintOrder: [BrowserSSLTrustScope] = []
    private var pendingBypasses: [String: BrowserPendingSSLTrustBypass] = [:]
    private var pendingTokenOrder: [String] = []
    private let tokenLifetime: TimeInterval
    private let maximumPendingBypassCount: Int
    private let maximumRetainedRequestBodyBytes: Int
    private let now: () -> Date

    init(
        tokenLifetime: TimeInterval = 24 * 60 * 60,
        maximumPendingBypassCount: Int = 32,
        maximumRetainedRequestBodyBytes: Int = 1_048_576,
        now: @escaping () -> Date = { Date.now }
    ) {
        self.tokenLifetime = tokenLifetime
        self.maximumPendingBypassCount = max(1, maximumPendingBypassCount)
        self.maximumRetainedRequestBodyBytes = max(0, maximumRetainedRequestBodyBytes)
        self.now = now
    }

    func recordObservedServerTrust(_ trust: SecTrust, for protectionSpace: URLProtectionSpace) {
        guard let scope = BrowserSSLTrustScope(protectionSpace: protectionSpace),
              let fingerprint = BrowserServerTrustFingerprint(serverTrust: trust) else {
            return
        }
        recordObservedServerTrustFingerprint(fingerprint, for: scope)
    }

    func recordObservedServerTrustFingerprint(
        _ fingerprint: BrowserServerTrustFingerprint,
        for scope: BrowserSSLTrustScope
    ) {
        observedFingerprints[scope] = fingerprint
        observedFingerprintOrder.removeAll { $0 == scope }
        observedFingerprintOrder.append(scope)
        enforceObservedFingerprintLimit()
    }

    func isBypassed(protectionSpace: URLProtectionSpace, serverTrust: SecTrust) -> Bool {
        guard let scope = BrowserSSLTrustScope(protectionSpace: protectionSpace),
              let fingerprint = BrowserServerTrustFingerprint(serverTrust: serverTrust) else {
            return false
        }
        return isBypassed(scope: scope, fingerprint: fingerprint)
    }

    func isBypassed(scope: BrowserSSLTrustScope, fingerprint: BrowserServerTrustFingerprint) -> Bool {
        bypassedTrusts.contains(BrowserSSLTrustGrant(scope: scope, fingerprint: fingerprint))
    }

    func createPendingBypassAction(for request: URLRequest) -> URL? {
        guard let url = request.url,
              let scope = BrowserSSLTrustScope(url: url),
              let fingerprint = observedFingerprints[scope],
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
        clearObservedServerTrustFingerprints()
    }

    func hasPendingBypassToken(_ token: String) -> Bool {
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
        clearObservedServerTrustFingerprints()
        bypassedTrusts.removeAll()
        bypassedTrustOrder.removeAll()
    }

    private func clearObservedServerTrustFingerprints() {
        observedFingerprints.removeAll()
        observedFingerprintOrder.removeAll()
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

    private func enforceObservedFingerprintLimit() {
        while observedFingerprintOrder.count > maximumPendingBypassCount {
            let scope = observedFingerprintOrder.removeFirst()
            observedFingerprints.removeValue(forKey: scope)
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
