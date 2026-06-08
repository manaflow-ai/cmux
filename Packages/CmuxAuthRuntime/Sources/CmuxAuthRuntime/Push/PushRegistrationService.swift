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
    /// Bumped on every local mute mutation. A server hydration snapshots this
    /// before its GET and refuses to overwrite local state if it changed during
    /// the (awaited, actor-reentrant) fetch — the local change is newer and is
    /// already being PUT to the server, so the GET result is stale and must not
    /// clobber it (which would otherwise drop a just-tapped mute/unmute).
    private var localMutationGeneration = 0

    private static let enabledKey = "cmux.notifications.pushEnabled"
    private static let cachedTokenKey = "cmux.notifications.deviceTokenHex"
    /// Prefix for the per-user muted-workspace cache key. The set is persisted
    /// under a key NAMESPACED BY THE STACK USER ID (`<prefix>.<userId>`), so a
    /// different account signing in on the same device reads/writes its own key
    /// and can never see or overwrite the previous account's mutes. This makes
    /// cross-account leakage impossible by construction, independent of how the
    /// refresh/mutation/sign-out tasks interleave — a task started under user A
    /// always targets A's key. A signed-out service (no user id) uses a single
    /// anonymous key so an opt-in-before-sign-in still persists until hydration.
    private static let mutedWorkspacesKeyPrefix = "cmux.notifications.mutedWorkspaceIDs"
    /// Prefix for the per-user "muted set has local changes not yet confirmed on
    /// the server" flag. Set when a toggle is persisted, cleared only on a
    /// successful PUT. Hydration consults it: if the user has an unsynced local
    /// change (e.g. a mute made during a transient network failure), hydration
    /// re-pushes local instead of overwriting it with the stale server set, so a
    /// failed upload never silently loses the user's mute on the next launch.
    private static let mutesPendingKeyPrefix = "cmux.notifications.mutedWorkspaceIDs.pending"
    private static let signedOutUserKey = "__signedOut"
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

    public var mutedWorkspaceIDs: Set<String> {
        get async { cachedMutedWorkspaceIDs(forUserKey: await currentUserKey()) }
    }

    public func setWorkspaceMuted(_ workspaceId: String, muted: Bool) async {
        let trimmed = workspaceId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Resolve the per-user key BEFORE mutating, so this write lands in the
        // signed-in user's namespace even if the task runs after another account
        // has signed in — it simply targets the original user's key, never the
        // new account's. This is what makes cross-account leakage impossible.
        let userKey = await currentUserKey()
        var set = cachedMutedWorkspaceIDs(forUserKey: userKey)
        if muted {
            guard set.count < Self.maxMutedWorkspaces || set.contains(trimmed) else { return }
            set.insert(trimmed)
        } else {
            set.remove(trimmed)
        }
        // Persist so the choice survives even if the upload fails or the app dies
        // mid-flight. Mark it unsynced until a PUT confirms it, and bump the
        // generation so an in-flight hydration knows a newer local change landed.
        defaults.set(Array(set).sorted(), forKey: Self.mutedKey(forUserKey: userKey))
        defaults.set(true, forKey: Self.pendingKey(forUserKey: userKey))
        localMutationGeneration &+= 1
        await syncMutedWorkspaces()
    }

    /// Test-only seam: awaited inside ``hydrateMutedWorkspacesFromServer()``
    /// after the server GET resolves but before the generation re-check, so a
    /// test can deterministically interleave a local mutation into the
    /// reentrancy window and prove the guard keeps local state. Always `nil` in
    /// production. Set via ``setAfterHydrationFetchForTesting(_:)``.
    private var afterHydrationFetchForTesting: (@Sendable () async -> Void)?

    /// Install the test-only hydration interleave hook. See
    /// ``afterHydrationFetchForTesting``.
    func setAfterHydrationFetchForTesting(_ hook: @escaping @Sendable () async -> Void) {
        afterHydrationFetchForTesting = hook
    }

    /// Test-only seam: awaited inside ``uploadMutedWorkspaces(_:expectedUserKey:)``
    /// after the request is built but before the user-match guard, so a test can
    /// deterministically switch accounts in the credential-binding window. Always
    /// `nil` in production.
    private var afterMakeMuteRequestForTesting: (@Sendable () async -> Void)?

    /// Install the test-only upload interleave hook. See
    /// ``afterMakeMuteRequestForTesting``.
    func setAfterMakeMuteRequestForTesting(_ hook: @escaping @Sendable () async -> Void) {
        afterMakeMuteRequestForTesting = hook
    }

    @discardableResult
    public func hydrateMutedWorkspacesFromServer() async -> Set<String> {
        let userKey = await currentUserKey()
        // The user has a local change that never confirmed on the server (e.g. a
        // mute made during a transient network failure). The server set is stale,
        // so re-push local instead of overwriting it — otherwise a failed upload
        // would silently lose the mute on the next launch and the workspace would
        // start pushing again.
        if defaults.bool(forKey: Self.pendingKey(forUserKey: userKey)) {
            await syncMutedWorkspaces()
            return cachedMutedWorkspaceIDs(forUserKey: userKey)
        }
        let generationAtStart = localMutationGeneration
        guard let serverSet = await fetchMutedWorkspaces() else {
            // Signed out or network failure: keep the local set so an offline
            // sign-in never wipes valid local state.
            return cachedMutedWorkspaceIDs(forUserKey: userKey)
        }
        await afterHydrationFetchForTesting?()
        // The GET was authenticated as whatever user was current at the fetch's
        // suspension point. If the account switched while it was in flight, this
        // response belongs to a DIFFERENT user and must not be saved under the
        // originally-captured key (that would store account B's set as account
        // A's). Abort the write; the now-current user hydrates separately.
        guard await currentUserKey() == userKey else {
            return cachedMutedWorkspaceIDs(forUserKey: userKey)
        }
        // A local mute/unmute for THIS user happened during the GET: that change
        // is newer and is already syncing to the server, so the GET response is
        // stale. Keep local instead of clobbering the just-tapped change.
        guard localMutationGeneration == generationAtStart else {
            return cachedMutedWorkspaceIDs(forUserKey: userKey)
        }
        let bounded = Array(serverSet).sorted().prefix(Self.maxMutedWorkspaces)
        defaults.set(Array(bounded), forKey: Self.mutedKey(forUserKey: userKey))
        return Set(bounded)
    }

    private var cachedTokenHex: String? {
        let hex = defaults.string(forKey: Self.cachedTokenKey)
        return (hex?.isEmpty == false) ? hex : nil
    }

    /// The current user's muted-set key component: the Stack user id when signed
    /// in, else the signed-out sentinel. Resolving this per access is what scopes
    /// the cache per account.
    private func currentUserKey() async -> String {
        await tokenProvider.currentUserID() ?? Self.signedOutUserKey
    }

    private static func mutedKey(forUserKey userKey: String) -> String {
        "\(mutedWorkspacesKeyPrefix).\(userKey)"
    }

    private static func pendingKey(forUserKey userKey: String) -> String {
        "\(mutesPendingKeyPrefix).\(userKey)"
    }

    private func cachedMutedWorkspaceIDs(forUserKey userKey: String) -> Set<String> {
        let raw = defaults.array(forKey: Self.mutedKey(forUserKey: userKey)) as? [String] ?? []
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
            // Upload the signed-in user's current persisted set. The server route
            // keys by the bearer's user id, so this matches the key we read.
            let userKey = await currentUserKey()
            let uploaded = await uploadMutedWorkspaces(
                cachedMutedWorkspaceIDs(forUserKey: userKey),
                expectedUserKey: userKey
            )
            // Clear the unsynced marker only when this upload confirmed the LATEST
            // local set: if a newer mutation arrived during the await it set
            // `mutesNeedResync`, so the snapshot we just uploaded is already stale.
            // Clearing now would unprotect that newer change, and if its resync
            // later fails (or the app dies) the next hydration could replace it
            // with the stale server set. Keep pending set until the final, current
            // upload succeeds.
            if uploaded && !mutesNeedResync {
                defaults.removeObject(forKey: Self.pendingKey(forUserKey: userKey))
            }
            // A mutation that arrived during the upload set the flag; drain it
            // with the now-current persisted set so the server converges.
        } while mutesNeedResync
    }

    @discardableResult
    private func uploadMutedWorkspaces(_ set: Set<String>, expectedUserKey: String) async -> Bool {
        // Idempotent full-set replace so the server always reflects the phone's
        // authoritative local state. Bounded to mirror the route's limit.
        let workspaceIds = Array(set).sorted().prefix(Self.maxMutedWorkspaces)
        guard let request = await makeRequest(
            method: "PUT",
            path: "/api/notifications/mutes",
            jsonBody: ["workspaceIds": Array(workspaceIds)]
        ) else { return false }
        await afterMakeMuteRequestForTesting?()
        // Bind the cached set to the credential: the request now carries
        // `tokenProvider`'s CURRENT bearer (resolved inside `makeRequest`). If the
        // account changed across the suspension since we read `expectedUserKey`'s
        // set, that bearer belongs to a DIFFERENT user, and PUTing this set would
        // overwrite the new account's server mutes with the old account's ids.
        // Abort instead; the original user re-syncs on their next sign-in (the
        // pending marker, keyed by their id, stays set). The token in `request`
        // was captured atomically with this check, so a later sign-in cannot make
        // an already-built request target the wrong user.
        guard await currentUserKey() == expectedUserKey else { return false }
        return await perform(request, label: "mute-sync")
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

    @discardableResult
    private func perform(_ request: URLRequest, label: String) async -> Bool {
        do {
            let (_, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                pushLog.error("\(label, privacy: .public) failed status=\(http.statusCode, privacy: .public)")
                return false
            }
            return true
        } catch {
            pushLog.error("\(label, privacy: .public) error=\(error.localizedDescription, privacy: .private)")
            return false
        }
    }
}
