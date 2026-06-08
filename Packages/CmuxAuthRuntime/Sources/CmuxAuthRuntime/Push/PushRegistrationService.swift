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

    /// Coalesces concurrent mute uploads into a single in-flight PUT. Swift
    /// actors are reentrant at `await`, so rapid `setWorkspaceMuted` calls could
    /// otherwise overlap and let an older full-set PUT land after a newer one
    /// (the server route is last-writer-wins with no revision). With these two
    /// flags only one upload runs at a time and, when a mutation arrives mid
    /// upload, exactly one more upload runs afterward reflecting the latest
    /// persisted set — so the final server state always matches local.
    private var isUploadingMutes = false
    private var mutesNeedResync = false

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
        // Persist first (synchronously, before any await) so the choice survives
        // even if the upload fails or the app dies mid-flight.
        defaults.set(Array(set).sorted(), forKey: Self.mutedWorkspacesKey)
        await syncMutedWorkspaces()
    }

    @discardableResult
    public func hydrateMutedWorkspacesFromServer() async -> Set<String> {
        guard let serverSet = await fetchMutedWorkspaces() else {
            // Signed out or network failure: keep the local set so an offline
            // sign-in never wipes valid local state.
            return cachedMutedWorkspaceIDs
        }
        let bounded = Array(serverSet).sorted().prefix(Self.maxMutedWorkspaces)
        defaults.set(Array(bounded), forKey: Self.mutedWorkspacesKey)
        return Set(bounded)
    }

    public func clearLocalMutedWorkspaces() async {
        defaults.removeObject(forKey: Self.mutedWorkspacesKey)
    }

    private var cachedTokenHex: String? {
        let hex = defaults.string(forKey: Self.cachedTokenKey)
        return (hex?.isEmpty == false) ? hex : nil
    }

    private var cachedMutedWorkspaceIDs: Set<String> {
        let raw = defaults.array(forKey: Self.mutedWorkspacesKey) as? [String] ?? []
        return Set(raw.filter { !$0.isEmpty })
    }

    /// Upload the muted set, coalescing concurrent calls so only one PUT is in
    /// flight at a time and the last upload always reflects the latest persisted
    /// set. See ``isUploadingMutes`` / ``mutesNeedResync``.
    private func syncMutedWorkspaces() async {
        if isUploadingMutes {
            mutesNeedResync = true
            return
        }
        isUploadingMutes = true
        defer { isUploadingMutes = false }
        repeat {
            mutesNeedResync = false
            await uploadMutedWorkspaces(cachedMutedWorkspaceIDs)
            // A mutation that arrived during the upload set the flag; drain it
            // with the now-current persisted set so the server converges.
        } while mutesNeedResync
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

    /// GET the server's muted set, or `nil` when signed out / on any failure (so
    /// callers fall back to the local cache instead of clobbering it to empty).
    private func fetchMutedWorkspaces() async -> Set<String>? {
        guard let request = await makeRequest(
            method: "GET",
            path: "/api/notifications/mutes",
            jsonBody: nil
        ) else { return nil }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                pushLog.error("mute-fetch failed status=\((response as? HTTPURLResponse)?.statusCode ?? -1, privacy: .public)")
                return nil
            }
            guard
                let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let ids = object["workspaceIds"] as? [String]
            else { return nil }
            return Set(ids.filter { !$0.isEmpty })
        } catch {
            pushLog.error("mute-fetch error=\(error.localizedDescription, privacy: .private)")
            return nil
        }
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

    private func makeRequest(method: String, path: String, jsonBody: [String: Any]?) async -> URLRequest? {
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
        if let jsonBody {
            request.httpBody = try? JSONSerialization.data(withJSONObject: jsonBody)
        }
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
