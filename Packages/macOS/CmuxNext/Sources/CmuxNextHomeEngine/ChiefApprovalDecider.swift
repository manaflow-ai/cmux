public import CmuxHomeRender
public import CmuxNextAgentPane
import CmuxNextCompat
public import CmuxNextWakeups
import Foundation

/// Answers one unchanged permission using the app's person proof and the existing once-only path.
/// A named Chief may use its own daemon, the default home's, or this app's; every read verifies
/// the session's exact parent home and refuses peers, turn sessions and the other-person floor.
@MainActor public final class ChiefApprovalDecider: HomeApprovalDeciding {
    private let home: ChiefHome
    private let app: AcpmuxEnvironment?
    private let work: BackgroundWork
    private let environment: @Sendable (ChiefHome) -> AcpmuxEnvironment?
    /// Uses the app's files lane and resolver; this type never resolves app services itself.
    public init(home: ChiefHome, app: AcpmuxEnvironment?, work: BackgroundWork,
                environment: @escaping @Sendable (ChiefHome) -> AcpmuxEnvironment?) {
        (self.home, self.app, self.work, self.environment) = (home, app, work, environment)
    }

    /// Answers the exact pending request only while the native click remains valid.
    public func decide(_ request: HomeApprovalRequest, allow: Bool, through gate: @escaping @Sendable (() -> Void) -> Bool) async -> HomeApprovalDecision {
        guard let session = Self.localSession(request.session),
              let expected = AcpmuxApprovalAnswerer.requestDigest(request.requestJSON),
              request.chief == "agent_mux" || request.chief.hasPrefix("agent_") else { return .refused }
        let brain = Self.brainHome(of: request.chief, in: home)
        let file = brain.muxHome.appendingPathComponent("optchat/home-id")
        let home = home, app = app, resolve = environment
        // Resolving a daemon checks its executable on disk, on the same files lane as the pinned ID.
        guard let (id, candidates) = try? await work.run(.userBlocking, mayBlock: .files, {
            let pinned = Self.readPinnedID(at: file)
            let id = pinned ?? String(ChiefHome.tabHost(muxHome: brain.muxHome).dropFirst(ChiefHome.tabHostPrefix.count))
            return (id, [resolve(brain), resolve(home), app].compactMap { $0 })
        }) else { return .refused }
        var seen = Set<String>()
        for environment in candidates where seen.insert(environment.socketPath).inserted {
            let answerer = AcpmuxApprovalAnswerer(environment: environment, chiefHomeID: id)
            await answerer.prepareForHome()
            guard let pending = await answerer.pendingAsk(session: session, permission: request.permission) else { continue }
            guard pending.approval.digest == expected else { return .expired }
            guard allow ? pending.allowOnce != nil : pending.denyOnce != nil else { return .refused }
            return await answerer.answerOnce(pending.approval, allow: allow, through: gate) ? .answered : .refused
        }
        // A missing response can mean an unavailable daemon; keep the card retryable.
        return .refused
    }

    private nonisolated static func readPinnedID(at file: URL) -> String? {
        pinnedID(try? String(blockingContentsOf: file, encoding: .utf8))
    }

    nonisolated static func localSession(_ session: String) -> String? {
        let bare = session.hasPrefix("local/") ? String(session.dropFirst(6)) : session
        guard !bare.isEmpty, bare != ".", bare != "..", bare.utf8.count <= 256, !bare.contains("/") else { return nil }
        return "local/" + bare
    }
    static func brainHome(of chief: String, in home: ChiefHome) -> ChiefHome {
        ChiefHome(root: ChiefHome.brainHome(muxHome: home.muxHome, chief: chief == "agent_mux" ? nil : chief), isolated: home.isolated)
    }
    nonisolated static func pinnedID(_ text: String?) -> String? {
        guard let value = text?.trimmingCharacters(in: .whitespacesAndNewlines), value.count == 8,
              value.allSatisfy({ "0123456789abcdef".contains($0) }) else { return nil }
        return value
    }
}
