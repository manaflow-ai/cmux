#if os(iOS)
import CMUXMobileCore
import CmuxPhonePush
import Foundation

/// One inline notification reply handed to the server-side inbox.
public struct RelayedReply: Equatable, Sendable {
    public let accountID: String?
    /// Stable idempotency key: the retry ladder re-sends the same id, so the
    /// server can never park one reply twice.
    public let replyId: String
    /// The Mac claimed by the originating push; the inbox routes by it.
    public let macDeviceId: String
    public let macInstallationID: String?
    public let macBuildID: String?
    /// The workspace claim from the push, if it carried one. The Mac uses it
    /// as the confined target, or as the preferred owner when retargeting is
    /// permitted.
    public let workspaceId: String?
    /// The exact terminal claim from the push.
    public let surfaceId: String
    /// The user's reply text, without the submit return.
    public let text: String
    public let macInstanceTag: String?
    /// Whether the notification may follow its surface to a new workspace.
    /// Workspace-confined notifications must keep their original claim when
    /// the Mac drains the parked reply.
    public let retargetsToLiveSurfaceOwner: Bool

    /// Creates a relayed reply from the parked reply's claims.
    public init(
        replyId: String,
        macDeviceId: String,
        workspaceId: String?,
        surfaceId: String,
        text: String,
        accountID: String? = nil,
        macInstallationID: String? = nil,
        macBuildID: String? = nil,
        macInstanceTag: String? = nil,
        retargetsToLiveSurfaceOwner: Bool = true
    ) {
        self.replyId = replyId
        self.accountID = accountID
        self.macDeviceId = macDeviceId
        self.macInstallationID = macInstallationID
        self.macBuildID = macBuildID
        self.workspaceId = workspaceId
        self.surfaceId = surfaceId
        self.text = text
        self.macInstanceTag = macInstanceTag
        self.retargetsToLiveSurfaceOwner = retargetsToLiveSurfaceOwner
    }
}

/// Seam over the presence worker's phone reply inbox
/// (`workers/presence/src/replies.ts`).
///
/// This is what makes inline replies survivable from a backgrounded app: the
/// phone's whole job shrinks to ONE authenticated HTTPS POST — no transport
/// dial, no pairing, no live Mac — and the Mac fetches and types the reply on
/// its own schedule. The production conformance is ``SystemReplyRelayClient``;
/// tests inject a fake to script acceptance and failure.
public protocol ReplyRelaying: Sendable {
    /// Parks the reply server-side. Returns `true` when the service accepted
    /// (including the idempotent duplicate case).
    func relay(_ reply: RelayedReply) async -> Bool
}

/// A relay that always declines, for previews and coordinators constructed
/// without a service origin; the reply then stays parked and the failure
/// notice reports it, which is the pre-relay behavior.
public struct NoopReplyRelay: ReplyRelaying {
    public init() {}
    public func relay(_ reply: RelayedReply) async -> Bool { false }
}

/// Production ``ReplyRelaying`` backed by `POST /v1/replies/e2e` on the presence
/// worker, authenticated with the caller's Stack access token.
public struct SystemReplyRelayClient: ReplyRelaying {
    private let serviceBaseURL: URL?
    private let accessToken: @Sendable () async -> String?
    private let keychainAccessGroup: String?
    private let session: URLSession
    private let now: @Sendable () -> Date
    private let envelopeCache = ReplyEnvelopeCache()
    /// One service-owned deadline suppresses every outer reply-ladder wake.
    /// The coordinator may check again after five seconds, but no HTTP request
    /// escapes until the server's deadline has passed.
    private let retryAfterGate = CmxRetryAfterGate()

    /// - Parameters:
    ///   - serviceBaseURL: The presence worker origin (the same one the
    ///     connectivity subscriber uses). `nil` disables the relay.
    ///   - accessToken: Live Stack access-token provider from the auth runtime.
    public init(
        serviceBaseURL: URL?,
        accessToken: @escaping @Sendable () async -> String?,
        keychainAccessGroup: String? = nil,
        session: URLSession = .shared,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.serviceBaseURL = serviceBaseURL
        self.accessToken = accessToken
        self.keychainAccessGroup = keychainAccessGroup
        self.session = session
        self.now = now
    }

    public func relay(_ reply: RelayedReply) async -> Bool {
        guard await retryAfterGate.remainingSeconds() == nil else { return false }
        guard let serviceBaseURL,
              var comps = URLComponents(
                  url: serviceBaseURL,
                  resolvingAgainstBaseURL: false
              ) else { return false }
        guard let token = await accessToken(), !token.isEmpty else { return false }
        comps.path = (comps.path.hasSuffix("/") ? String(comps.path.dropLast()) : comps.path)
            + "/v1/replies/e2e"
        guard let url = comps.url else { return false }
        guard let identity = try? PhonePushKeyStore.current(
            bundleID: Bundle.main.bundleIdentifier ?? "cmux",
            accessGroup: keychainAccessGroup
        ), let accountID = reply.accountID, !accountID.isEmpty else { return false }
        guard let macInstallationID = reply.macInstallationID, !macInstallationID.isEmpty else { return false }
        let tuple = PhonePushDeviceTuple(
            accountID: accountID,
            teamID: nil,
            iosBuildID: Bundle.main.bundleIdentifier ?? "cmux",
            iosInstallationID: identity.installationID,
            macDeviceID: reply.macDeviceId,
            macInstanceTag: reply.macInstanceTag,
            macBuildID: reply.macBuildID
        )
        guard reply.macBuildID != nil,
              let peer = PhonePushPeerKeyStore.pinnedDescriptor(for: tuple) else { return false }
        let issuedAt = now().timeIntervalSince1970
        let plaintext: [String: Any] = [
            "replyId": reply.replyId,
            "accountID": accountID,
            "macDeviceId": reply.macDeviceId,
            "surfaceId": reply.surfaceId,
            "retargetsToLiveSurfaceOwner": reply.retargetsToLiveSurfaceOwner,
            "text": reply.text,
            "issuedAtEpochSeconds": issuedAt,
            "expiresAtEpochSeconds": issuedAt + 15 * 60,
        ]
        var plaintextWithWorkspace = plaintext
        if let workspaceId = reply.workspaceId, !workspaceId.isEmpty { plaintextWithWorkspace["workspaceId"] = workspaceId }
        guard let plaintextData = try? JSONSerialization.data(withJSONObject: plaintextWithWorkspace),
              let candidate = try? PhonePushCrypto.encrypt(
                  plaintext: plaintextData,
                  tuple: tuple,
                  recipientPublicKey: peer.publicKey,
                  keyID: peer.keyID,
                  senderKeyID: identity.keyID,
                  senderPrivateKey: identity.privateKey,
                  installationID: macInstallationID
              ),
              let candidateData = try? JSONEncoder().encode(candidate) else { return false }
        let encryptedData = await envelopeCache.valueOrInsert(
            for: "\(reply.replyId)|\(peer.keyID)",
            candidate: candidateData
        )
        var body: [String: Any] = [
            "replyId": reply.replyId,
            "macDeviceId": reply.macDeviceId,
            "encryptedPayload": try! JSONSerialization.jsonObject(with: encryptedData),
        ]
        if let macInstanceTag = reply.macInstanceTag { body["macInstanceTag"] = macInstanceTag }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // Comfortably inside the reply lane's background window, long enough
        // for a cold TLS handshake on cellular.
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [])
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            if http.statusCode == 429 {
                let seconds = CmxRetryAfterPolicy.seconds(
                    from: http.value(forHTTPHeaderField: "Retry-After")
                ) ?? CmxRetryAfterPolicy.defaultRateLimitSeconds
                await retryAfterGate.extend(by: seconds)
            }
            return (200...299).contains(http.statusCode)
        } catch {
            return false
        }
    }
}

private actor ReplyEnvelopeCache {
    private struct Entry {
        let data: Data
        let insertedAt: Date
    }

    private static let maximumEntries = 128
    private static let lifetime: TimeInterval = 15 * 60
    private var values: [String: Entry] = [:]

    func valueOrInsert(for replyId: String, candidate: Data) -> Data {
        let now = Date()
        values = values.filter { now.timeIntervalSince($0.value.insertedAt) < Self.lifetime }
        if let value = values[replyId] { return value.data }
        while values.count >= Self.maximumEntries,
              let oldest = values.min(by: { $0.value.insertedAt < $1.value.insertedAt })?.key {
            values.removeValue(forKey: oldest)
        }
        values[replyId] = Entry(data: candidate, insertedAt: now)
        return candidate
    }
}
#endif
