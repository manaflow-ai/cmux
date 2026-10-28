import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextHomeEngine
import CmuxNextHostedChief
import Foundation

/// The Hosted Chief's wiring (CmuxNextHostedChief owns the copy and the brain check).
extension HomeService {
    func wireHostedChief() {
        guard let services else { return }
        // The auth, not Cloud; the feed only at the first call: Home is wired at launch, the feed starts with Cloud (p08-startup 020).
        let auth = services.cloudAuth
        let owner = chief
        hostedChief.wire(.init(
            apiBase: { FeedService.apiBaseURL(auth: auth) }, token: { try await auth.tokens().access },
            ops: { [weak appServices = services] body in
                guard let feed = appServices?.feed else { throw FeedServiceError.signedOut }
                return try await Self.hostedCall(feed, "v1/ops", body)
            },
            user: { auth.user.map { CloudIdentity.workerUserID(stackProjectID: auth.configuration.stackProjectID, stackUserID: $0.id) } },
            debugBuild: auth.configuration.isDebugBuild, owner: owner, localChief: Self.mux.id,
            refreshTab: { [weak self] in self?.refreshChiefTab() }))
    }

    /// One API Worker call for CmuxNextHostedChief: an owner refusal as ``HostedChiefError``.
    static func hostedCall(_ feed: FeedService, _ path: String, _ body: [String: Any]) async throws -> [String: Any] {
        do { return try await feed.call(path, body) } catch let FeedServiceError.owner(code, message) {
            throw HostedChiefError.owner(code: code, message: message)
        }
    }
}
