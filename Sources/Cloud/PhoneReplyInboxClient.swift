import CmuxAuthRuntime
import Foundation
import OSLog

private let phoneReplyLog = Logger(subsystem: "dev.cmux", category: "phone-reply-inbox")

/// One phone inline-notification reply parked in the presence worker
/// (`workers/presence/src/replies.ts`). Wire and stored shapes are identical.
struct PhoneReplyRecord: Decodable, Equatable, Sendable {
    let replyId: String
    let macDeviceId: String
    let workspaceId: String
    let surfaceId: String
    let notificationId: String
    let text: String
    let createdAtMs: UInt64
    let expiresAtMs: UInt64
}

/// HTTPS half of the phone reply inbox: fetch this Mac's pending replies and
/// acknowledge processed ones against the presence worker, authenticated the
/// same way as ``PresenceHeartbeatClient`` (Stack bearer, resolved service
/// URL). Delivery into the terminal is ``PhoneReplyInboxCoordinator``'s job.
final class PhoneReplyInboxClient {
    @MainActor static let shared = PhoneReplyInboxClient()

    @MainActor private weak var auth: AuthCoordinator?
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    @MainActor
    func configure(auth: AuthCoordinator) {
        self.auth = auth
    }

    private struct FetchEnvelope: Decodable {
        let replies: [PhoneReplyRecord]
    }

    /// Pending replies addressed to this Mac, oldest first, or nil when the
    /// service is unreachable / the user is signed out (callers retry on the
    /// next nudge; the entries wait out their server-side TTL).
    @MainActor
    func fetchPending() async -> [PhoneReplyRecord]? {
        guard let request = await authorizedRequest(
            path: "/v1/replies",
            queryItems: [URLQueryItem(
                name: "macDeviceId",
                value: MobileHostIdentity.deviceID()
            )]
        ) else { return nil }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else { return nil }
            return try JSONDecoder().decode(FetchEnvelope.self, from: data).replies
        } catch {
            phoneReplyLog.error("reply fetch failed: \(String(describing: error), privacy: .private)")
            return nil
        }
    }

    /// Remove processed replies server-side. Best-effort and idempotent: a
    /// missed ack means one duplicate fetch that the coordinator's seen-set
    /// drops locally.
    @MainActor
    @discardableResult
    func acknowledge(replyIds: [String]) async -> Bool {
        guard !replyIds.isEmpty else { return true }
        guard var request = await authorizedRequest(path: "/v1/replies/ack") else { return false }
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try? JSONSerialization.data(
            withJSONObject: ["replyIds": replyIds],
            options: []
        )
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else { return false }
            return true
        } catch {
            phoneReplyLog.error("reply ack failed: \(String(describing: error), privacy: .private)")
            return false
        }
    }

    @MainActor
    private func authorizedRequest(
        path: String,
        queryItems: [URLQueryItem] = []
    ) async -> URLRequest? {
        guard let auth,
              let baseURL = PresenceHeartbeatClient.resolvedServiceURL() else { return nil }
        let tokens: (accessToken: String, refreshToken: String)
        do {
            tokens = try await auth.currentTokens()
        } catch {
            return nil // signed out; the reply waits out its server TTL
        }
        guard var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        comps.path = (comps.path.hasSuffix("/") ? String(comps.path.dropLast()) : comps.path)
            + path
        if !queryItems.isEmpty {
            comps.queryItems = queryItems
        }
        guard let url = comps.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        return request
    }
}
