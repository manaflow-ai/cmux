import Foundation
import Testing
@testable import CmuxAuthRuntime

/// Records every URLRequest the push service performs, returning 200.
final class RecordingURLProtocol: URLProtocol, @unchecked Sendable {
    // Mutations are serialized by the URL loading system; a lock-free actor
    // box keeps captured requests for assertions.
    nonisolated(unsafe) static let recorder = RequestRecorder()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // URLProtocol nils out `httpBody` when the loading system converts it to
        // a stream, so read the stream to capture the JSON body for assertions.
        let bodyData = Self.bodyData(from: request)
        let host = request.url?.host ?? ""
        let method = request.httpMethod ?? "?"
        let captured = RecordedRequest(
            host: host,
            method: method,
            path: request.url?.path ?? "",
            body: bodyData
        )
        // Snapshot the canned response synchronously so the response is ready
        // before this loader finishes (the recorder actor read is deferred).
        // Keyed by host+method so a test can fail a specific verb (e.g. PUT).
        let cannedResponse = Self.responseStore.response(forHost: host, method: method)
        Task { await RecordingURLProtocol.recorder.record(captured) }
        let status = cannedResponse?.status ?? 200
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if method == "GET", let body = cannedResponse?.body {
            client?.urlProtocol(self, didLoad: body)
        } else {
            client?.urlProtocol(self, didLoad: Data())
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    /// Per-(host, method) canned responses, keyed by the test's unique API host.
    /// `startLoading()` is synchronous and cannot await the recorder actor, so a
    /// lock-guarded store provides real synchronization for parallel test writes
    /// + protocol reads (distinct keys alone do NOT make a `Dictionary` thread
    /// safe).
    static let responseStore = CannedResponseStore()

    struct CannedResponse: Sendable {
        var status: Int = 200
        var body: Data?
    }

    override func stopLoading() {}

    private static func bodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 4096
        var buffer = [UInt8](repeating: 0, count: size)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: size)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

/// Thread-safe canned-response store for ``RecordingURLProtocol``, keyed by
/// host+method so a test can script a specific verb (e.g. a failing PUT).
final class CannedResponseStore: @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [String: RecordingURLProtocol.CannedResponse] = [:]

    private func key(host: String, method: String) -> String { "\(method) \(host)" }

    /// Script the GET response for `host` (the common case: a hydration body).
    func set(_ response: RecordingURLProtocol.CannedResponse, for host: String) {
        set(response, forHost: host, method: "GET")
    }

    func set(_ response: RecordingURLProtocol.CannedResponse, forHost host: String, method: String) {
        lock.lock()
        defer { lock.unlock() }
        responses[key(host: host, method: method)] = response
    }

    func response(forHost host: String, method: String) -> RecordingURLProtocol.CannedResponse? {
        lock.lock()
        defer { lock.unlock() }
        return responses[key(host: host, method: method)]
    }
}

struct RecordedRequest: Sendable {
    let host: String
    let method: String
    let path: String
    let body: Data?
}

/// The recorder is process-global because `URLProtocol` has no per-session hook,
/// and Swift Testing runs cases in parallel, so every assertion is scoped to the
/// calling test's unique API host (`makeService` assigns one per test). Without
/// host scoping, a concurrent test's PUT would clobber another's "last" request.
actor RequestRecorder {
    private(set) var requests: [RecordedRequest] = []
    func record(_ request: RecordedRequest) { requests.append(request) }

    /// HTTP methods recorded for `host`, in order.
    func methods(host: String) -> [String] {
        requests.filter { $0.host == host }.map(\.method)
    }

    /// Whether any request was recorded for `host`.
    func hasRequests(host: String) -> Bool {
        requests.contains { $0.host == host }
    }

    /// Number of requests recorded for `host`.
    func count(host: String) -> Int {
        requests.filter { $0.host == host }.count
    }

    /// The decoded `{ workspaceId, muted }` of the most recent per-workspace mute
    /// mutation POST for `host`, or `nil` if no such request was recorded.
    func lastMuteMutation(host: String) -> (workspaceId: String, muted: Bool)? {
        guard let request = requests.last(where: {
            $0.host == host && $0.method == "POST" && $0.path.hasSuffix("/api/notifications/mutes")
        }),
              let body = request.body,
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let workspaceId = object["workspaceId"] as? String,
              let muted = object["muted"] as? Bool
        else { return nil }
        return (workspaceId, muted)
    }

    /// All mute mutation POSTs for `host`, in order.
    func muteMutations(host: String) -> [(workspaceId: String, muted: Bool)] {
        requests.compactMap { request -> (String, Bool)? in
            guard request.host == host, request.method == "POST",
                  request.path.hasSuffix("/api/notifications/mutes"),
                  let body = request.body,
                  let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let workspaceId = object["workspaceId"] as? String,
                  let muted = object["muted"] as? Bool
            else { return nil }
            return (workspaceId, muted)
        }
    }
}

/// A token provider whose reported user id can change between calls, to exercise
/// the account-switch-mid-sync credential-binding guard.
actor MutableUserTokenProvider: TokenProviding {
    private var userID: String?
    init(userID: String?) { self.userID = userID }
    func setUserID(_ id: String?) { userID = id }
    func accessToken() async throws -> String { "access" }
    func refreshToken() async -> String? { "refresh" }
    func forceRefreshAccessToken() async throws -> String { "access" }
    func currentUserID() async -> String? { userID }
}

struct FakeTokenProvider: TokenProviding {
    var access: String? = "access"
    var refresh: String? = "refresh"
    var userID: String? = "user-default"
    func accessToken() async throws -> String {
        guard let access else { throw AuthError.unauthorized }
        return access
    }
    func refreshToken() async -> String? { refresh }
    func forceRefreshAccessToken() async throws -> String {
        guard let access else { throw AuthError.unauthorized }
        return access
    }
    func currentUserID() async -> String? { userID }
}

@Suite struct PushRegistrationServiceTests {
    /// A unique API host per test so the process-global recorder can scope its
    /// assertions to the calling test under parallel execution.
    private func makeService(
        tokenProvider: any TokenProviding = FakeTokenProvider()
    ) -> (PushRegistrationService, UserDefaults, String) {
        let suite = "push-test-\(UUID().uuidString)"
        let host = "t-\(UUID().uuidString).example.test"
        let defaults = UserDefaults(suiteName: suite)!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecordingURLProtocol.self]
        let service = PushRegistrationService(
            tokenProvider: tokenProvider,
            apiBaseURL: "https://\(host)",
            bundleID: "dev.cmux.ios",
            apnsEnvironment: "sandbox",
            suiteName: suite,
            session: URLSession(configuration: configuration)
        )
        return (service, defaults, host)
    }

    @Test func disabledByDefault() async {
        let (service, _, _) = makeService()
        #expect(await service.isEnabled == false)
    }

    @Test func registeringWhileDisabledCachesButDoesNotUpload() async {
        let (service, _, host) = makeService()
        await service.register(deviceToken: Data([0xAB, 0xCD]))
        // No upload because notifications are off.
        #expect(await RecordingURLProtocol.recorder.methods(host: host).isEmpty)
    }

    @Test func enablingUploadsCachedToken() async {
        let (service, defaults, host) = makeService()
        await service.register(deviceToken: Data([0xAB, 0xCD]))
        await service.setEnabled(true)
        #expect(defaults.bool(forKey: "cmux.notifications.pushEnabled"))
        #expect(await RecordingURLProtocol.recorder.methods(host: host).contains("POST"))
    }

    @Test func disablingDeletesServerToken() async {
        let (service, _, host) = makeService()
        await service.register(deviceToken: Data([0xAB, 0xCD]))
        await service.setEnabled(true)
        await service.setEnabled(false)
        #expect(await RecordingURLProtocol.recorder.methods(host: host).contains("DELETE"))
    }

    // MARK: - Per-workspace mute

    @Test func mutedWorkspacesEmptyByDefault() async {
        let (service, _, _) = makeService()
        #expect(await service.mutedWorkspaceIDs.isEmpty)
    }

    @Test func mutingPostsASinglePerWorkspaceMutation() async {
        let (service, _, host) = makeService()
        await service.setWorkspaceMuted("ws-a", muted: true)
        #expect(await service.mutedWorkspaceIDs == ["ws-a"])
        // Each toggle is a single per-workspace add/remove, not a full-set replace.
        #expect(await RecordingURLProtocol.recorder.lastMuteMutation(host: host)?.workspaceId == "ws-a")
        #expect(await RecordingURLProtocol.recorder.lastMuteMutation(host: host)?.muted == true)

        await service.setWorkspaceMuted("ws-b", muted: true)
        #expect(await service.mutedWorkspaceIDs == ["ws-a", "ws-b"])
        // The second POST carries only ws-b, leaving ws-a's server row untouched.
        #expect(await RecordingURLProtocol.recorder.lastMuteMutation(host: host)?.workspaceId == "ws-b")
        let mutations = await RecordingURLProtocol.recorder.muteMutations(host: host)
        #expect(mutations.count == 2)
    }

    @Test func unmutingPostsARemovalForThatWorkspaceOnly() async {
        let (service, _, host) = makeService()
        await service.setWorkspaceMuted("ws-a", muted: true)
        await service.setWorkspaceMuted("ws-b", muted: true)
        await service.setWorkspaceMuted("ws-a", muted: false)
        #expect(await service.mutedWorkspaceIDs == ["ws-b"])
        let last = await RecordingURLProtocol.recorder.lastMuteMutation(host: host)
        #expect(last?.workspaceId == "ws-a")
        #expect(last?.muted == false)
    }

    @Test func mutedSetSurvivesAcrossServiceInstances() async {
        let suite = "push-mute-\(UUID().uuidString)"
        let host = "t-\(UUID().uuidString).example.test"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecordingURLProtocol.self]
        func makeOne() -> PushRegistrationService {
            PushRegistrationService(
                tokenProvider: FakeTokenProvider(),
                apiBaseURL: "https://\(host)",
                bundleID: "dev.cmux.ios",
                apnsEnvironment: "sandbox",
                suiteName: suite,
                session: URLSession(configuration: configuration)
            )
        }
        await makeOne().setWorkspaceMuted("ws-persist", muted: true)
        // A fresh instance over the same suite reads the persisted set.
        #expect(await makeOne().mutedWorkspaceIDs == ["ws-persist"])
    }

    @Test func mutingWithoutAuthStillPersistsLocally() async {
        // No tokens → upload is skipped, but the local choice must persist.
        let (service, _, host) = makeService(tokenProvider: FakeTokenProvider(access: nil, refresh: nil))
        await service.setWorkspaceMuted("ws-a", muted: true)
        #expect(await service.mutedWorkspaceIDs == ["ws-a"])
        #expect(await RecordingURLProtocol.recorder.hasRequests(host: host) == false)
    }

    @Test func rapidTogglesConvergeToTheFinalLocalSet() async {
        let (service, _, _) = makeService()
        // Fire many toggles back-to-back. Each is an independent idempotent POST,
        // so the local set ends at the union of the final intents.
        async let a: Void = service.setWorkspaceMuted("ws-a", muted: true)
        async let b: Void = service.setWorkspaceMuted("ws-b", muted: true)
        async let c: Void = service.setWorkspaceMuted("ws-a", muted: false)
        async let d: Void = service.setWorkspaceMuted("ws-c", muted: true)
        _ = await (a, b, c, d)
        #expect(await service.mutedWorkspaceIDs == ["ws-b", "ws-c"])
    }

    @Test func rapidSameWorkspaceToggleConvergesServerToLastAction() async {
        // mute then immediately unmute the SAME workspace while the first POST is
        // in flight. The per-workspace drain serializes them so the LAST action
        // (unmute) is the final POST the server sees and no pending delta lingers,
        // regardless of HTTP completion order.
        let (service, _, host) = makeService()
        async let m: Void = service.setWorkspaceMuted("ws-a", muted: true)
        async let u: Void = service.setWorkspaceMuted("ws-a", muted: false)
        _ = await (m, u)
        // Local reflects the last action.
        #expect(await service.mutedWorkspaceIDs.isEmpty)
        // The last mutation the server received is the unmute, and nothing stays
        // pending (a confirmed sync of the final intent cleared it).
        let last = await RecordingURLProtocol.recorder.lastMuteMutation(host: host)
        #expect(last?.workspaceId == "ws-a")
        #expect(last?.muted == false)
        // A hydration with an empty server set must NOT re-mute it (no stale delta).
        RecordingURLProtocol.responseStore.set(
            .init(body: try? JSONSerialization.data(withJSONObject: ["workspaceIds": [String]()])),
            for: host
        )
        #expect(await service.hydrateMutedWorkspacesFromServer().isEmpty)
    }

    // MARK: - Sign-in hydration / sign-out clear (per-user scoping)

    @Test func hydrateReplacesLocalWithServerSet() async {
        let (service, _, host) = makeService()
        // A previous account left "ws-stale" cached locally.
        await service.setWorkspaceMuted("ws-stale", muted: true)
        #expect(await service.mutedWorkspaceIDs == ["ws-stale"])

        // The signed-in user's server set is ["ws-server-1", "ws-server-2"].
        RecordingURLProtocol.responseStore.set(
            .init(body: try? JSONSerialization.data(withJSONObject: ["workspaceIds": ["ws-server-1", "ws-server-2"]])),
            for: host
        )
        let hydrated = await service.hydrateMutedWorkspacesFromServer()
        // Local is replaced wholesale by the server set; the stale id is gone.
        #expect(hydrated == ["ws-server-1", "ws-server-2"])
        #expect(await service.mutedWorkspaceIDs == ["ws-server-1", "ws-server-2"])
    }

    @Test func hydrateDoesNotClobberAConcurrentUnsyncedLocalMutation() async {
        let (service, _, host) = makeService()
        // The server set already has ws-server (e.g. from another device).
        RecordingURLProtocol.responseStore.set(
            .init(body: try? JSONSerialization.data(withJSONObject: ["workspaceIds": ["ws-server"]])),
            for: host
        )
        // The just-tapped mutation's POST fails, so it stays an unsynced pending
        // delta. Interleave it into the hydration window (after the GET resolves)
        // via the test seam. Hydration merges pending deltas over the server set,
        // so the just-tapped change is never lost AND the server's own mute is
        // adopted — both survive.
        RecordingURLProtocol.responseStore.set(.init(status: 503, body: nil), forHost: host, method: "POST")
        await service.setAfterHydrationFetchForTesting { [service] in
            await service.setWorkspaceMuted("ws-just-tapped", muted: true)
        }
        let hydrated = await service.hydrateMutedWorkspacesFromServer()
        #expect(hydrated.contains("ws-just-tapped"))
        #expect(hydrated.contains("ws-server"))
        #expect(await service.mutedWorkspaceIDs == ["ws-just-tapped", "ws-server"])
    }

    @Test func hydrateKeepsLocalWhenServerUnreachable() async {
        // No tokens → the GET is never made; the local set must survive so an
        // offline sign-in does not wipe valid local state.
        let (service, _, _) = makeService(tokenProvider: FakeTokenProvider(access: nil, refresh: nil))
        await service.setWorkspaceMuted("ws-local", muted: true)
        let hydrated = await service.hydrateMutedWorkspacesFromServer()
        #expect(hydrated == ["ws-local"])
        #expect(await service.mutedWorkspaceIDs == ["ws-local"])
    }

    @Test func hydrateKeepsLocalOnServerError() async {
        let (service, _, host) = makeService()
        await service.setWorkspaceMuted("ws-local", muted: true)
        // Server returns 500 → keep local rather than clobber to empty.
        RecordingURLProtocol.responseStore.set(.init(status: 500, body: nil), for: host)
        let hydrated = await service.hydrateMutedWorkspacesFromServer()
        #expect(hydrated == ["ws-local"])
        #expect(await service.mutedWorkspaceIDs == ["ws-local"])
    }

    @Test func hydrateToEmptyServerSetClearsLocal() async {
        let (service, _, host) = makeService()
        await service.setWorkspaceMuted("ws-stale", muted: true)
        // The signed-in user has no server mutes → local should end up empty.
        RecordingURLProtocol.responseStore.set(
            .init(body: try? JSONSerialization.data(withJSONObject: ["workspaceIds": [String]()])),
            for: host
        )
        let hydrated = await service.hydrateMutedWorkspacesFromServer()
        #expect(hydrated.isEmpty)
        #expect(await service.mutedWorkspaceIDs.isEmpty)
    }

    // MARK: - Per-user namespaced persistence (cross-account isolation)

    @Test func mutedSetIsNamespacedPerUser() async {
        // Two users over the SAME UserDefaults suite (same device): each must see
        // only their own muted set, so a different account on the same device can
        // never read or write the previous account's mutes.
        let suite = "push-multiuser-\(UUID().uuidString)"
        let host = "t-\(UUID().uuidString).example.test"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecordingURLProtocol.self]
        func service(forUser userID: String?) -> PushRegistrationService {
            PushRegistrationService(
                tokenProvider: FakeTokenProvider(userID: userID),
                apiBaseURL: "https://\(host)",
                bundleID: "dev.cmux.ios",
                apnsEnvironment: "sandbox",
                suiteName: suite,
                session: URLSession(configuration: configuration)
            )
        }
        await service(forUser: "user-a").setWorkspaceMuted("ws-a", muted: true)
        // User B on the same device sees an empty set, not user A's "ws-a".
        #expect(await service(forUser: "user-b").mutedWorkspaceIDs.isEmpty)
        await service(forUser: "user-b").setWorkspaceMuted("ws-b", muted: true)
        // Each account's set is independent and intact.
        #expect(await service(forUser: "user-a").mutedWorkspaceIDs == ["ws-a"])
        #expect(await service(forUser: "user-b").mutedWorkspaceIDs == ["ws-b"])
    }

    @Test func mutationStartedUnderOneUserDoesNotLeakToAnother() async {
        // A write resolved under user A's key cannot land in user B's namespace
        // even when the same suite is shared (the leak the per-user key prevents).
        let suite = "push-leak-\(UUID().uuidString)"
        let host = "t-\(UUID().uuidString).example.test"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecordingURLProtocol.self]
        func service(forUser userID: String?) -> PushRegistrationService {
            PushRegistrationService(
                tokenProvider: FakeTokenProvider(userID: userID),
                apiBaseURL: "https://\(host)",
                bundleID: "dev.cmux.ios",
                apnsEnvironment: "sandbox",
                suiteName: suite,
                session: URLSession(configuration: configuration)
            )
        }
        await service(forUser: "user-a").setWorkspaceMuted("ws-secret", muted: true)
        // User B never sees user A's id even after A persisted it.
        #expect(!(await service(forUser: "user-b").mutedWorkspaceIDs).contains("ws-secret"))
    }

    // MARK: - Unsynced-local durability (failed POST not lost by later hydrate)

    @Test func hydrateRePushesUnsyncedLocalChangeInsteadOfLosingIt() async {
        let (service, _, host) = makeService()
        // The mute POST fails (transient server/network error), so the change is
        // persisted locally + as a pending delta but never confirmed on the server.
        RecordingURLProtocol.responseStore.set(.init(status: 503, body: nil), forHost: host, method: "POST")
        await service.setWorkspaceMuted("ws-a", muted: true)
        #expect(await service.mutedWorkspaceIDs == ["ws-a"])

        // The server still reports an empty set. A naive hydrate would overwrite
        // local and lose the mute; instead it must merge the pending delta on top.
        RecordingURLProtocol.responseStore.set(
            .init(body: try? JSONSerialization.data(withJSONObject: ["workspaceIds": [String]()])),
            for: host
        )
        // Let the retried POST succeed this time so the pending delta can clear.
        RecordingURLProtocol.responseStore.set(.init(status: 200, body: nil), forHost: host, method: "POST")
        let hydrated = await service.hydrateMutedWorkspacesFromServer()
        // The locally-made mute survives the hydrate.
        #expect(hydrated == ["ws-a"])
        #expect(await service.mutedWorkspaceIDs == ["ws-a"])
        // It re-posted the unsynced delta rather than adopting the empty server set.
        let last = await RecordingURLProtocol.recorder.lastMuteMutation(host: host)
        #expect(last?.workspaceId == "ws-a")
        #expect(last?.muted == true)
    }

    @Test func muteMutationAbortsIfAccountSwitchesMidFlight() async {
        // User A mutes; the account switches to B in the credential-binding window
        // (after the request is built, before the user-match guard). The POST must
        // abort so A's id is never sent with B's bearer (which would mutate B's
        // server mutes).
        let suite = "push-switch-\(UUID().uuidString)"
        let host = "t-\(UUID().uuidString).example.test"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecordingURLProtocol.self]
        let provider = MutableUserTokenProvider(userID: "user-a")
        let service = PushRegistrationService(
            tokenProvider: provider,
            apiBaseURL: "https://\(host)",
            bundleID: "dev.cmux.ios",
            apnsEnvironment: "sandbox",
            suiteName: suite,
            session: URLSession(configuration: configuration)
        )
        await service.setAfterMakeMuteRequestForTesting { await provider.setUserID("user-b") }
        await service.setWorkspaceMuted("ws-a", muted: true)
        // No mute mutation reached the server (it was aborted at the guard).
        #expect(await RecordingURLProtocol.recorder.lastMuteMutation(host: host) == nil)
        // A's local set + pending delta survive (A re-syncs on next sign-in).
        await provider.setUserID("user-a")
        #expect(await service.mutedWorkspaceIDs == ["ws-a"])
    }

    @Test func hydrateDoesNotPersistAnotherAccountsResponseUnderCapturedKey() async {
        // User A's hydration GET is in flight; the account switches to B before
        // the response is applied. The GET response was authenticated as B, so it
        // must NOT be saved under A's key.
        let suite = "push-hydrate-switch-\(UUID().uuidString)"
        let host = "t-\(UUID().uuidString).example.test"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecordingURLProtocol.self]
        let provider = MutableUserTokenProvider(userID: "user-a")
        let service = PushRegistrationService(
            tokenProvider: provider,
            apiBaseURL: "https://\(host)",
            bundleID: "dev.cmux.ios",
            apnsEnvironment: "sandbox",
            suiteName: suite,
            session: URLSession(configuration: configuration)
        )
        RecordingURLProtocol.responseStore.set(
            .init(body: try? JSONSerialization.data(withJSONObject: ["workspaceIds": ["ws-from-b"]])),
            for: host
        )
        // Switch accounts in the window after the GET resolves, before the write.
        await service.setAfterHydrationFetchForTesting { await provider.setUserID("user-b") }
        let hydrated = await service.hydrateMutedWorkspacesFromServer()
        // The write was aborted: A's (empty) key is unchanged, and the returned
        // set is A's local, not B's server response.
        #expect(hydrated.isEmpty)
        await provider.setUserID("user-a")
        #expect(await service.mutedWorkspaceIDs.isEmpty)
        // B's id was not saved under A's key.
        #expect(!(await service.mutedWorkspaceIDs).contains("ws-from-b"))
    }

    @Test func failedPostsKeepPendingDeltasSoHydrationMergesThemBackIn() async {
        // Every mute POST fails, so the changes are persisted locally + as pending
        // deltas but never confirmed. A later hydration (server reports empty) must
        // merge the pending deltas on top of the server set rather than adopting
        // the empty set and losing the mutes.
        let (service, _, host) = makeService()
        RecordingURLProtocol.responseStore.set(.init(status: 503, body: nil), forHost: host, method: "POST")
        await service.setWorkspaceMuted("ws-a", muted: true)
        await service.setWorkspaceMuted("ws-b", muted: true)
        #expect(await service.mutedWorkspaceIDs == ["ws-a", "ws-b"])

        RecordingURLProtocol.responseStore.set(
            .init(body: try? JSONSerialization.data(withJSONObject: ["workspaceIds": [String]()])),
            for: host
        )
        let hydrated = await service.hydrateMutedWorkspacesFromServer()
        #expect(hydrated == ["ws-a", "ws-b"])
        #expect(await service.mutedWorkspaceIDs == ["ws-a", "ws-b"])
    }

    @Test func hydrationMergesAnotherDevicesMuteWithThisDevicesPendingDelta() async {
        // The multi-device case the per-workspace model fixes: another device
        // muted ws-other (now in the server set); this device has an unsynced local
        // mute of ws-mine. Hydration must end with BOTH, not lose either.
        let (service, _, host) = makeService()
        RecordingURLProtocol.responseStore.set(.init(status: 503, body: nil), forHost: host, method: "POST")
        await service.setWorkspaceMuted("ws-mine", muted: true)

        RecordingURLProtocol.responseStore.set(
            .init(body: try? JSONSerialization.data(withJSONObject: ["workspaceIds": ["ws-other"]])),
            for: host
        )
        let hydrated = await service.hydrateMutedWorkspacesFromServer()
        #expect(hydrated == ["ws-mine", "ws-other"])
        #expect(await service.mutedWorkspaceIDs == ["ws-mine", "ws-other"])
    }

    @Test func hydrateAdoptsServerSetOnceLocalChangeIsConfirmed() async {
        let (service, _, host) = makeService()
        // First mute's POST succeeds (default 200), clearing its pending delta.
        await service.setWorkspaceMuted("ws-a", muted: true)
        // Now the server is the source of truth: it reports a different set.
        RecordingURLProtocol.responseStore.set(
            .init(body: try? JSONSerialization.data(withJSONObject: ["workspaceIds": ["ws-server"]])),
            for: host
        )
        let hydrated = await service.hydrateMutedWorkspacesFromServer()
        // With no unsynced delta, hydration adopts the server set.
        #expect(hydrated == ["ws-server"])
        #expect(await service.mutedWorkspaceIDs == ["ws-server"])
    }
}
