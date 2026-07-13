import Foundation

final class DiffViewerSessionTrustRegistry {
    static let shared = DiffViewerSessionTrustRegistry()

    private struct LiveHTTPSession {
        let scheme: String
        let host: String
        let port: Int
        let createdAt: Date
    }

    private let lock = NSLock()
    private var liveHTTPSessions: [String: LiveHTTPSession] = [:]
    private let maxSessionAge: TimeInterval = 24 * 60 * 60

    func registerLiveHTTPURL(_ url: URL, token: String, now: Date = Date()) -> Bool {
        guard let components = CmuxDiffViewerURLSchemeHandler.diffViewerComponents(from: url),
              components.token == token,
              let session = Self.liveHTTPSession(from: url, now: now) else {
            return false
        }
        lock.lock()
        pruneExpiredSessionsLocked(now: now)
        liveHTTPSessions[token] = session
        lock.unlock()
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
        lock.lock()
        pruneExpiredSessionsLocked(now: now)
        let registered = liveHTTPSessions[token]
        lock.unlock()
        return registered?.scheme == candidate.scheme &&
            registered?.host == candidate.host &&
            registered?.port == candidate.port
    }

    private static func liveHTTPSession(from url: URL, now: Date) -> LiveHTTPSession? {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host == "127.0.0.1",
              let port = url.port else { return nil }
        return LiveHTTPSession(scheme: scheme, host: "127.0.0.1", port: port, createdAt: now)
    }

    private func pruneExpiredSessionsLocked(now: Date) {
        liveHTTPSessions = liveHTTPSessions.filter {
            now.timeIntervalSince($0.value.createdAt) <= maxSessionAge
        }
    }
}
