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

    /// `(userKey, workspaceId)` pairs with an in-flight mute sync, so a second
    /// toggle for the same user+workspace updates the pending intent (already
    /// persisted) and lets the running drain loop pick it up, instead of starting
    /// an overlapping POST. Keyed by user too, so one account's in-flight sync
    /// never blocks another account's drain for the same workspace.
    private var pendingWorkspaceMuteSyncs: Set<String> = []

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
    /// Prefix for the per-user map of unsynced mute intentions
    /// (`workspaceId -> muted`), persisted as JSON. A toggle records its intent
    /// here and removes it on a confirmed server POST. Hydration re-applies these
    /// over the server set (local intent wins) and re-POSTs them, so a toggle made
    /// during a transient network failure is neither lost nor reverted by a later
    /// server hydration, while another device's independent mutes still merge in.
    private static let mutesPendingKeyPrefix = "cmux.notifications.mutedWorkspaceIDs.pendingDeltas"
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
        // Persist locally + record the unsynced intent so the choice survives a
        // failed POST or app death, then push the SINGLE delta. A per-workspace
        // add/remove (not a full-set replace) keeps multiple devices on one
        // account from clobbering each other's mutes.
        defaults.set(Array(set).sorted(), forKey: Self.mutedKey(forUserKey: userKey))
        setPendingDelta(workspaceId: trimmed, muted: muted, forUserKey: userKey)
        await drainPendingDelta(workspaceId: trimmed, userKey: userKey)
    }

    /// Push the workspace's pending intent and converge to the user's LATEST
    /// action. Serialized per workspace by a re-drain loop: each POST sends the
    /// current pending value; if a newer toggle changed the intent while it was in
    /// flight, the loop re-POSTs the new value so the server ends at the final
    /// action regardless of POST completion order. Clears the delta only when the
    /// confirmed value still matches the current pending intent.
    private func drainPendingDelta(workspaceId: String, userKey: String) async {
        // Key the in-flight set by BOTH user and workspace: pending deltas are
        // per-user, so user A's in-flight `ws-1` sync must not block user B's
        // `ws-1` sync (which loops over B's own pending map). Keying by workspace
        // alone would drop B's mutation until a later hydration.
        let lockKey = "\(userKey)\u{1}\(workspaceId)"
        if pendingWorkspaceMuteSyncs.contains(lockKey) { return }
        pendingWorkspaceMuteSyncs.insert(lockKey)
        defer { pendingWorkspaceMuteSyncs.remove(lockKey) }
        while let intent = pendingDeltas(forUserKey: userKey)[workspaceId] {
            let confirmed = await postMuteMutation(
                workspaceId: workspaceId, muted: intent, expectedUserKey: userKey
            )
            guard confirmed else { return } // leave pending; a later sync retries
            // If the intent changed during the POST, loop and send the new value.
            guard clearPendingDelta(workspaceId: workspaceId, ifMuted: intent, forUserKey: userKey) else {
                continue
            }
            return
        }
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

    /// Test-only seam: awaited inside ``postMuteMutation(workspaceId:muted:expectedUserKey:)``
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
        guard let fetched = await fetchMutedWorkspaces() else {
            // Signed out or network failure: keep the local set so an offline
            // sign-in never wipes valid local state.
            return cachedMutedWorkspaceIDs(forUserKey: userKey)
        }
        let serverSet = fetched.ids
        await afterHydrationFetchForTesting?()
        // Bind the response to the account we meant to hydrate. The server echoes
        // the user id it authenticated this GET as; if it does not match the key we
        // captured, the request raced an account switch (token/`currentUserID` can
        // cycle A->B->A out of phase) and the set belongs to a DIFFERENT user — do
        // not write it under the captured key. Also re-check the current user, so a
        // server that does not echo an id still falls back to the prior guard.
        if let authedId = fetched.authenticatedUserId, authedId != userKey {
            return cachedMutedWorkspaceIDs(forUserKey: userKey)
        }
        guard await currentUserKey() == userKey else {
            return cachedMutedWorkspaceIDs(forUserKey: userKey)
        }
        // Adopt the server set (authoritative across the account's devices), then
        // re-apply any unsynced local deltas on top so a toggle made during a
        // transient failure is neither lost nor reverted; another device's
        // independent mutes still merge in via the server set.
        let pending = pendingDeltas(forUserKey: userKey)
        var merged = serverSet
        for (workspaceId, muted) in pending {
            if muted { merged.insert(workspaceId) } else { merged.remove(workspaceId) }
        }
        let bounded = Set(Array(merged).sorted().prefix(Self.maxMutedWorkspaces))
        defaults.set(Array(bounded).sorted(), forKey: Self.mutedKey(forUserKey: userKey))
        // Re-POST the unsynced deltas so the server converges; drop each on
        // success only if its intent still matches (a concurrent newer toggle is
        // preserved). Best-effort: a still-failing delta stays pending for next time.
        for (workspaceId, muted) in pending {
            if await postMuteMutation(workspaceId: workspaceId, muted: muted, expectedUserKey: userKey) {
                clearPendingDelta(workspaceId: workspaceId, ifMuted: muted, forUserKey: userKey)
            }
        }
        return bounded
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

    /// The user's unsynced mute intentions (`workspaceId -> muted`), persisted as
    /// a `[String: Bool]` dictionary.
    private func pendingDeltas(forUserKey userKey: String) -> [String: Bool] {
        defaults.dictionary(forKey: Self.pendingKey(forUserKey: userKey)) as? [String: Bool] ?? [:]
    }

    private func setPendingDelta(workspaceId: String, muted: Bool, forUserKey userKey: String) {
        var map = pendingDeltas(forUserKey: userKey)
        map[workspaceId] = muted
        defaults.set(map, forKey: Self.pendingKey(forUserKey: userKey))
    }

    /// Clear the pending delta for `workspaceId` only if its current intent still
    /// equals `ifMuted` (the value the just-confirmed POST sent). A newer toggle
    /// that changed the intent mid-flight is preserved so the last user action
    /// wins regardless of POST completion order.
    /// - Returns: `true` when the delta was cleared (intent matched), `false` when
    ///   a newer intent is still pending.
    @discardableResult
    private func clearPendingDelta(workspaceId: String, ifMuted: Bool, forUserKey userKey: String) -> Bool {
        var map = pendingDeltas(forUserKey: userKey)
        guard map[workspaceId] == ifMuted else { return false }
        map.removeValue(forKey: workspaceId)
        if map.isEmpty {
            defaults.removeObject(forKey: Self.pendingKey(forUserKey: userKey))
        } else {
            defaults.set(map, forKey: Self.pendingKey(forUserKey: userKey))
        }
        return true
    }

    /// POST a single per-workspace mute add/remove. Idempotent server-side, so
    /// concurrent toggles need no coalescing, and a per-workspace mutation never
    /// clobbers another device's independent mutes.
    /// - Returns: `true` when the server confirmed the mutation.
    @discardableResult
    private func postMuteMutation(workspaceId: String, muted: Bool, expectedUserKey: String) async -> Bool {
        guard let request = await makeRequest(
            method: "POST",
            path: "/api/notifications/mutes",
            jsonBody: ["workspaceId": workspaceId, "muted": muted]
        ) else { return false }
        await afterMakeMuteRequestForTesting?()
        // Bind the mutation to the credential: the request carries `tokenProvider`'s
        // CURRENT bearer (resolved inside `makeRequest`). If the account changed
        // across the suspension since we read `expectedUserKey`, that bearer
        // belongs to a DIFFERENT user; sending would mutate the wrong account.
        // Abort; the original user re-syncs from its pending deltas on next
        // sign-in. The token in `request` was captured atomically with this check.
        guard await currentUserKey() == expectedUserKey else { return false }
        // Confirm via the echoed user id that the server applied this to the
        // intended account (a token that cycled out of phase would mutate the
        // wrong user). Treat a mismatch as a non-confirm so the pending delta
        // stays for the correct account's next sync.
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                pushLog.error("mute-mutate failed status=\((response as? HTTPURLResponse)?.statusCode ?? -1, privacy: .public)")
                return false
            }
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let authedId = object["userId"] as? String, authedId != expectedUserKey {
                return false
            }
            return true
        } catch {
            pushLog.error("mute-mutate error=\(error.localizedDescription, privacy: .private)")
            return false
        }
    }

    /// GET the server's muted set + the user id the server authenticated, or
    /// `nil` when signed out / on any failure (so callers fall back to the local
    /// cache instead of clobbering it to empty).
    private func fetchMutedWorkspaces() async -> (ids: Set<String>, authenticatedUserId: String?)? {
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
            // The server echoes the id of the user it authenticated this request
            // as. Returning it lets hydration bind the response to the account it
            // meant to fetch, even if the token/`currentUserID` cycled mid-request.
            let authenticatedUserId = object["userId"] as? String
            return (Set(ids.filter { !$0.isEmpty }), authenticatedUserId)
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
