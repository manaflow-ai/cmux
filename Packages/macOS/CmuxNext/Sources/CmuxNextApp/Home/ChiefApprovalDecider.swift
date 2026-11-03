import CmuxHomeRender
import CmuxNextAgentPane
import CmuxNextHomeEngine
import Foundation
import os

/// Answers one unchanged permission using the app's person proof and the existing once-only path.
/// A named Chief may use its own daemon, the default home's, or this app's; every read verifies
/// the session's exact parent home and refuses peers, turn sessions and the other-person floor.
@MainActor final class ChiefApprovalDecider: HomeApprovalDeciding {
    private let home: ChiefHome
    private let app: AcpmuxEnvironment?
    private let rollout = OSAllocatedUnfairLock(initialState: false)
    var enabled: Bool {
        get { rollout.withLock { $0 } }
        set { rollout.withLock { $0 = newValue } }
    }
    init(home: ChiefHome, app: AcpmuxEnvironment?, enabled: Bool) {
        (self.home, self.app) = (home, app)
        self.enabled = enabled
    }

    func decide(_ request: HomeApprovalRequest, allow: Bool, through gate: @escaping @Sendable (() -> Void) -> Bool) async -> HomeApprovalDecision {
        guard enabled, let session = Self.localSession(request.session),
              let expected = AcpmuxApprovalAnswerer.requestDigest(request.requestJSON),
              request.chief == "agent_mux" || request.chief.hasPrefix("agent_") else { return .refused }
        let brain = Self.brainHome(of: request.chief, in: home)
        let file = brain.muxHome.appendingPathComponent("optchat/home-id")
        // task-owner: one tiny pinned-home read, kept off the main actor.
        let pinned = await Task.detached { Self.pinnedID(try? String(contentsOf: file, encoding: .utf8)) }.value
        let id = pinned ?? String(ChiefHomeAcpmux.host(muxHome: brain.muxHome).dropFirst("chief:".count))
        var seen = Set<String>()
        let candidates = [ChiefHomeAcpmux.environment(home: brain), ChiefHomeAcpmux.environment(home: home), app].compactMap { $0 }
        for environment in candidates where seen.insert(environment.socketPath).inserted {
            let answerer = AcpmuxApprovalAnswerer(environment: environment, chiefHomeID: id)
            await answerer.prepareForHome()
            guard enabled else { return .refused }
            guard let pending = await answerer.pendingAsk(session: session, permission: request.permission) else { continue }
            guard pending.approval.digest == expected else { return .expired }
            guard allow ? pending.allowOnce != nil : pending.denyOnce != nil else { return .refused }
            let rollout = rollout
            return await answerer.answerOnce(pending.approval, allow: allow, through: { bytes in
                // Recheck on the socket queue immediately before claiming the click.
                guard rollout.withLock({ $0 }) else { return false }
                return gate(bytes)
            }) ? .answered : .refused
        }
        return .expired
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
