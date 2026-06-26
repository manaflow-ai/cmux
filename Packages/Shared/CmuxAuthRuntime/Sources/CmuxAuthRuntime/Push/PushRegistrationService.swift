public import Foundation
import OSLog

private let pushLog = Logger(subsystem: "ai.manaflow.cmux", category: "push")

/// Owns the push opt-in state and the device-token sync with the cmux web API.
///
/// Replaces the iOS `NotificationManager.shared` singleton and its
/// `AuthManager.shared` / `AppEnvironment.current` reach-ins: construct it once
/// at the app composition root with an injected ``TokenProviding``, API base
/// URL, bundle id, `UserDefaults(suiteName:)`, and `URLSession`, then inject it
/// as `any PushRegistering`.
///
/// Privacy: notifications are **off by default**. Nothing (not even a device
/// token) is uploaded until the user enables them via ``setEnabled(_:)``.
public actor PushRegistrationService: PushRegistering {
    private let tokenProvider: any TokenProviding
    private let apiBaseURL: String
    private let bundleID: String
    private let apnsEnvironment: String
    private let defaults: UserDefaults
    private let session: URLSession

    private static let enabledKey = "cmux.notifications.pushEnabled"
    private static let cachedTokenKey = "cmux.notifications.deviceTokenHex"

    /// Creates a push registration service.
    ///
    /// - Parameters:
    ///   - tokenProvider: Supplies the access/refresh tokens for authenticated
    ///     API calls (production: ``AuthCoordinator``).
    ///   - apiBaseURL: The cmux web API base URL (no trailing slash).
    ///   - bundleID: The app bundle identifier sent with the device token.
    ///   - apnsEnvironment: `"sandbox"` for DEBUG builds, `"production"` otherwise.
    ///   - suiteName: The `UserDefaults(suiteName:)` for the opt-in flag + last
    ///     device token. `nil` uses `.standard`. The suite is opened inside the
    ///     actor so callers never send a non-`Sendable` `UserDefaults` across
    ///     the isolation boundary.
    ///   - session: The URLSession used for API calls.
    public init(
        tokenProvider: any TokenProviding,
        apiBaseURL: String,
        bundleID: String,
        apnsEnvironment: String,
        suiteName: String? = nil,
        session: sending URLSession = .shared
    ) {
        self.tokenProvider = tokenProvider
        self.apiBaseURL = apiBaseURL
        self.bundleID = bundleID
        self.apnsEnvironment = apnsEnvironment
        if let suiteName, let suite = UserDefaults(suiteName: suiteName) {
            self.defaults = suite
        } else {
            self.defaults = .standard
        }
        self.session = session
    }

    public var isEnabled: Bool { defaults.bool(forKey: Self.enabledKey) }

    public func setEnabled(_ enabled: Bool) async {
        defaults.set(enabled, forKey: Self.enabledKey)
        if enabled {
            await syncTokenIfPossible()
        } else {
            await unregisterFromServer()
        }
    }

    public func register(deviceToken: Data) async {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        defaults.set(hex, forKey: Self.cachedTokenKey)
        guard isEnabled else { return }
        await upload(tokenHex: hex)
    }

    public func syncTokenIfPossible() async {
        guard isEnabled, let hex = cachedTokenHex else { return }
        await upload(tokenHex: hex)
    }

    public func unregisterFromServer() async {
        guard let hex = cachedTokenHex else { return }
        await sendDelete(tokenHex: hex)
    }

    /// Delete the device token from the server at sign-out, authenticating
    /// with the credentials captured before the local-first clear destroyed
    /// the live session.
    ///
    /// - Parameters:
    ///   - accessToken: The captured (or teardown-minted) access token.
    ///   - refreshToken: The captured refresh token.
    public func unregisterFromServer(accessToken: String?, refreshToken: String?) async {
        guard let hex = cachedTokenHex else { return }
        // Sign-out path: never fall back to the live token provider. The
        // local-first sign-out cleared it, and a sign-in racing the bounded
        // teardown can repopulate it with the NEXT account's tokens; the
        // DELETE must authenticate as the signing-out account or not run at
        // all. An incomplete pair means the access-token mint failed
        // (offline), where the DELETE could not have succeeded anyway.
        guard let accessToken, let refreshToken else {
            pushLog.info("Skipping push-token unregister at sign-out: captured credentials incomplete")
            return
        }
        await sendDelete(tokenHex: hex, capturedAccessToken: accessToken, capturedRefreshToken: refreshToken)
    }

    private var cachedTokenHex: String? {
        let hex = defaults.string(forKey: Self.cachedTokenKey)
        return (hex?.isEmpty == false) ? hex : nil
    }

    private func upload(tokenHex: String) async {
        guard let request = await makeRequest(
            method: "POST",
            path: "/api/device-tokens",
            body: [
                "deviceToken": tokenHex,
                "bundleId": bundleID,
                "environment": apnsEnvironment,
                "platform": "ios",
            ]
        ) else { return }
        await perform(request, label: "register")
    }

    private func sendDelete(
        tokenHex: String,
        capturedAccessToken: String? = nil,
        capturedRefreshToken: String? = nil
    ) async {
        guard let request = await makeRequest(
            method: "DELETE",
            path: "/api/device-tokens",
            body: ["deviceToken": tokenHex],
            capturedAccessToken: capturedAccessToken,
            capturedRefreshToken: capturedRefreshToken
        ) else { return }
        await perform(request, label: "unregister")
    }

    private func makeRequest(
        method: String,
        path: String,
        body: [String: String],
        capturedAccessToken: String? = nil,
        capturedRefreshToken: String? = nil
    ) async -> URLRequest? {
        let accessToken: String
        let refreshToken: String
        if let capturedAccessToken, let capturedRefreshToken {
            // Sign-out path: the live provider is already cleared by the
            // local-first sign-out; the captured pair is the only credential.
            accessToken = capturedAccessToken
            refreshToken = capturedRefreshToken
        } else {
            do {
                accessToken = try await tokenProvider.accessToken()
            } catch {
                return nil
            }
            guard let liveRefreshToken = await tokenProvider.refreshToken() else { return nil }
            refreshToken = liveRefreshToken
        }
        guard let url = URL(string: apiBaseURL + path) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(refreshToken, forHTTPHeaderField: "X-Stack-Refresh-Token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func perform(_ request: URLRequest, label: String) async {
        do {
            // Route through the redirect-preserving delegate so a canonicalizing
            // 301/302 keeps this POST/DELETE a POST/DELETE instead of silently
            // becoming a body-less GET that never registers the token (#6270).
            let (_, response) = try await session.data(
                for: request,
                delegate: RedirectMethodPreservingDelegate.shared
            )
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                pushLog.error("\(label, privacy: .public) failed status=\(http.statusCode, privacy: .public)")
            }
        } catch {
            pushLog.error("\(label, privacy: .public) error=\(error.localizedDescription, privacy: .private)")
        }
    }
}
