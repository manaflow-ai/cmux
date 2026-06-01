import Foundation

/// Owns the iOS push-notification opt-in state and the device-token sync with
/// the cmux web API. Foundation-only (no UIKit) so it stays usable from any
/// layer; the app target drives the actual `registerForRemoteNotifications` /
/// authorization, then hands the token here via ``register(deviceToken:)``.
///
/// Privacy: the feature is **off by default**. Nothing is uploaded — not even a
/// device token — until the user explicitly enables it via ``setEnabled(_:)``.
@MainActor
public final class NotificationManager {
    public static let shared = NotificationManager()

    // Existing singleton manager (predates the inject-everything package rule);
    // `.standard` holds the app-level opt-in preference + last device token.
    private let defaults: UserDefaults
    private let session: URLSession

    private static let enabledKey = "cmux.notifications.pushEnabled"
    private static let cachedTokenKey = "cmux.notifications.deviceTokenHex"

    init(defaults: UserDefaults = .standard, session: URLSession = .shared) {
        self.defaults = defaults
        self.session = session
    }

    /// Whether the user has opted into phone notifications. Default false.
    public var isEnabled: Bool { defaults.bool(forKey: Self.enabledKey) }

    /// Persist the opt-in flag. The UI layer is responsible for requesting
    /// system authorization + `registerForRemoteNotifications()` when enabling;
    /// enabling here also re-uploads any cached token, and disabling removes the
    /// token from the server so the device stops receiving pushes.
    public func setEnabled(_ enabled: Bool) async {
        defaults.set(enabled, forKey: Self.enabledKey)
        if enabled {
            await syncTokenIfPossible()
        } else {
            await unregisterFromServer()
        }
    }

    /// Store + upload an APNs device token (from the AppDelegate). Caches it
    /// regardless so a later opt-in / sign-in can re-register, but only uploads
    /// when the user is opted in.
    public func register(deviceToken: Data) async {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        defaults.set(hex, forKey: Self.cachedTokenKey)
        guard isEnabled else { return }
        await upload(tokenHex: hex)
    }

    /// Re-upload the cached token (e.g. after sign-in). No-op unless opted in.
    public func syncTokenIfPossible() async {
        guard isEnabled, let hex = cachedTokenHex else { return }
        await upload(tokenHex: hex)
    }

    /// Remove the cached token from the server (on disable or sign-out).
    public func unregisterFromServer() async {
        guard let hex = cachedTokenHex else { return }
        await sendDelete(tokenHex: hex)
    }

    private var cachedTokenHex: String? {
        let hex = defaults.string(forKey: Self.cachedTokenKey)
        return (hex?.isEmpty == false) ? hex : nil
    }

    private static var apnsEnvironment: String {
        #if DEBUG
        return "sandbox"
        #else
        return "production"
        #endif
    }

    private func upload(tokenHex: String) async {
        guard let request = await makeRequest(
            method: "POST",
            path: "/api/device-tokens",
            body: [
                "deviceToken": tokenHex,
                "bundleId": Bundle.main.bundleIdentifier ?? "",
                "environment": Self.apnsEnvironment,
                "platform": "ios",
            ]
        ) else { return }
        await perform(request, label: "register")
    }

    private func sendDelete(tokenHex: String) async {
        guard let request = await makeRequest(
            method: "DELETE",
            path: "/api/device-tokens",
            body: ["deviceToken": tokenHex]
        ) else { return }
        await perform(request, label: "unregister")
    }

    private func makeRequest(method: String, path: String, body: [String: String]) async -> URLRequest? {
        let accessToken: String
        do {
            accessToken = try await AuthManager.shared.getAccessToken()
        } catch {
            return nil
        }
        guard let refreshToken = await AuthManager.shared.getRefreshToken() else { return nil }
        guard let url = URL(string: AppEnvironment.current.apiBaseURL + path) else { return nil }
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
            let (_, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                NSLog("cmux.push %@ failed status=%d", label, http.statusCode)
            }
        } catch {
            NSLog("cmux.push %@ error=%@", label, error.localizedDescription)
        }
    }
}
