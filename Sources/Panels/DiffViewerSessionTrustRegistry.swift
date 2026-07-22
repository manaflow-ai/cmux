import Foundation

@MainActor
final class DiffViewerSessionTrustRegistry {
    static let shared = DiffViewerSessionTrustRegistry()

    private var liveHTTPSessions: [String: DiffViewerLiveHTTPSession] = [:]
    private let maxSessionAge: TimeInterval = 24 * 60 * 60

    func registerLiveHTTPURL(_ url: URL, token: String, now: Date = Date()) -> Bool {
        guard let components = CmuxDiffViewerURLSchemeHandler.diffViewerComponents(from: url),
              components.token == token,
              let session = Self.liveHTTPSession(from: url, now: now) else {
            return false
        }
        pruneExpiredSessionsLocked(now: now)
        liveHTTPSessions[token] = session
        return true
    }

    func isTrustedDiffViewerURL(_ url: URL?, now: Date = Date()) -> Bool {
        guard let url,
              let token = DiffCommentsBridge.diffViewerToken(from: url) else {
            return false
        }
        if url.scheme == CmuxDiffViewerURLSchemeHandler.scheme {
            return CmuxDiffViewerURLSchemeHandler.shared.hasActiveSession(token: token, now: now)
        }
        guard let candidate = Self.liveHTTPSession(from: url, now: now) else { return false }
        pruneExpiredSessionsLocked(now: now)
        guard var registered = liveHTTPSessions[token],
              registered.scheme == candidate.scheme,
              registered.host == candidate.host,
              registered.port == candidate.port else {
            return false
        }
        registered.lastAuthenticatedActivityAt = now
        liveHTTPSessions[token] = registered
        return true
    }

    private static func liveHTTPSession(from url: URL, now: Date) -> DiffViewerLiveHTTPSession? {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host == "127.0.0.1",
              let port = url.port else { return nil }
        return DiffViewerLiveHTTPSession(
            scheme: scheme,
            host: "127.0.0.1",
            port: port,
            lastAuthenticatedActivityAt: now
        )
    }

    private func pruneExpiredSessionsLocked(now: Date) {
        liveHTTPSessions = liveHTTPSessions.filter {
            now.timeIntervalSince($0.value.lastAuthenticatedActivityAt) <= maxSessionAge
        }
    }
}
