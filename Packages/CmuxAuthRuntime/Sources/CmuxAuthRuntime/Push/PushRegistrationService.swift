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
    private static let mutedWorkspacesKey = "cmux.notifications.mutedWorkspaceIDs"
    /// Defensive upper bound on the muted set, mirroring the web route's
    /// per-request limit so a corrupted/oversized local set never tries to
    /// upload an unbounded body.
    private static let maxMutedWorkspaces = 500

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

    public var mutedWorkspaceIDs: Set<String> { cachedMutedWorkspaceIDs }

    public func setWorkspaceMuted(_ workspaceId: String, muted: Bool) async {
        let trimmed = workspaceId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var set = cachedMutedWorkspaceIDs
        if muted {
            guard set.count < Self.maxMutedWorkspaces || set.contains(trimmed) else { return }
            set.insert(trimmed)
        } else {
            set.remove(trimmed)
        }
        // Persist first so the choice survives even if the upload fails; the
        // next sign-in / sync re-uploads the authoritative local set.
        defaults.set(Array(set).sorted(), forKey: Self.mutedWorkspacesKey)
        await uploadMutedWorkspaces(set)
    }

    public func syncMutedWorkspacesIfPossible() async {
        await uploadMutedWorkspaces(cachedMutedWorkspaceIDs)
    }

    private var cachedTokenHex: String? {
        let hex = defaults.string(forKey: Self.cachedTokenKey)
        return (hex?.isEmpty == false) ? hex : nil
    }

    private var cachedMutedWorkspaceIDs: Set<String> {
        let raw = defaults.array(forKey: Self.mutedWorkspacesKey) as? [String] ?? []
        return Set(raw.filter { !$0.isEmpty })
    }

    private func uploadMutedWorkspaces(_ set: Set<String>) async {
        // Idempotent full-set replace so the server always reflects the phone's
        // authoritative local state. Bounded to mirror the route's limit.
        let workspaceIds = Array(set).sorted().prefix(Self.maxMutedWorkspaces)
        guard let request = await makeRequest(
            method: "PUT",
            path: "/api/notifications/mutes",
            jsonBody: ["workspaceIds": Array(workspaceIds)]
        ) else { return }
        await perform(request, label: "mute-sync")
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

    private func sendDelete(tokenHex: String) async {
        guard let request = await makeRequest(
            method: "DELETE",
            path: "/api/device-tokens",
            body: ["deviceToken": tokenHex]
        ) else { return }
        await perform(request, label: "unregister")
    }

    private func makeRequest(method: String, path: String, body: [String: String]) async -> URLRequest? {
        await makeRequest(method: method, path: path, jsonBody: body)
    }

    private func makeRequest(method: String, path: String, jsonBody: [String: Any]) async -> URLRequest? {
        let accessToken: String
        do {
            accessToken = try await tokenProvider.accessToken()
        } catch {
            return nil
        }
        guard let refreshToken = await tokenProvider.refreshToken() else { return nil }
        guard let url = URL(string: apiBaseURL + path) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(refreshToken, forHTTPHeaderField: "X-Stack-Refresh-Token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: jsonBody)
        return request
    }

    private func perform(_ request: URLRequest, label: String) async {
        do {
            let (_, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                pushLog.error("\(label, privacy: .public) failed status=\(http.statusCode, privacy: .public)")
            }
        } catch {
            pushLog.error("\(label, privacy: .public) error=\(error.localizedDescription, privacy: .private)")
        }
    }
}
