public import CmuxHomeRender
public import CmuxNextAgentPane
import CmuxNextCompat
public import CmuxNextWakeups
import Foundation

/// Answers one unchanged permission using the app's person proof and the existing once-only path.
/// A named Chief may use its own daemon, the default home's, or this app's; every read verifies
/// the session's exact parent home and refuses peers, turn sessions and the other-person floor.
@MainActor public final class ChiefApprovalDecider: HomeApprovalDeciding, HomeQuestionDeciding {
    private let home: ChiefHome
    private let app: AcpmuxEnvironment?
    private let work: BackgroundWork
    private let environment: @Sendable (ChiefHome) -> AcpmuxEnvironment?
    /// The daemon's unsigned decision for a question answer (`DaemonHomeSource.questionDecision`);
    /// nil: question answers are refused.
    public var unsignedQuestionDecision: (@MainActor (HomeQuestionRequest) async throws -> String)?
    /// Uses the app's files lane and resolver; this type never resolves app services itself.
    /// `questions` builds the unsigned decisions for question answers; nil: they are refused.
    public init(home: ChiefHome, app: AcpmuxEnvironment?, work: BackgroundWork,
                environment: @escaping @Sendable (ChiefHome) -> AcpmuxEnvironment?, questions: DaemonHomeSource? = nil) {
        (self.home, self.app, self.work, self.environment) = (home, app, work, environment)
        if let questions {
            unsignedQuestionDecision = { request in
                try await questions.questionDecision(conversation: request.conversation, message: request.message,
                                                     partIndex: request.partIndex, answer: request.answerJSON)
            }
        }
    }

    /// Answers the exact pending request only while the native click remains valid.
    public func decide(_ request: HomeApprovalRequest, allow: Bool, through gate: @escaping @Sendable (() -> Void) -> Bool) async -> HomeApprovalDecision {
        guard let session = Self.localSession(request.session),
              let expected = AcpmuxApprovalAnswerer.requestDigest(request.requestJSON),
              Self.isChief(request.chief), let (id, candidates) = await candidates(chief: request.chief) else { return .refused }
        for environment in candidates {
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

    /// Signs the person's decision for one question answer, only while the native click stays
    /// valid. The daemon builds the unsigned decision from the stored question and the live prompt.
    /// The app then re-reads that prompt on its own person line, in each daemon this Chief may use,
    /// before it signs (``AcpmuxApprovalAnswerer/signQuestionDecision(_:through:)``).
    public func decide(_ request: HomeQuestionRequest, through gate: @escaping @Sendable (() -> Void) -> Bool) async -> HomeQuestionDecision {
        guard Self.isChief(request.chief), let unsignedQuestionDecision,
              let unsigned = try? await unsignedQuestionDecision(request),
              let (id, candidates) = await candidates(chief: request.chief) else { return .refused }
        for environment in candidates {
            let answerer = AcpmuxApprovalAnswerer(environment: environment, chiefHomeID: id)
            await answerer.prepareForHome()
            switch await answerer.signQuestionDecision(unsigned, through: gate) {
            case .notHere: continue
            case .signed(let decision): return .signed(decision)
            case .expired: return .expired
            case .refused: return .refused
            }
        }
        // A missing response can mean an unavailable daemon; keep the card retryable.
        return .refused
    }

    nonisolated static func isChief(_ chief: String) -> Bool { chief == "agent_mux" || chief.hasPrefix("agent_") }

    /// The Chief's pinned home ID and the daemons it may use, each once: its own, the default
    /// home's, this app's. Resolving a daemon checks its executable on disk, on the same files lane
    /// as the pinned ID.
    private func candidates(chief: String) async -> (String, [AcpmuxEnvironment])? {
        let brain = Self.brainHome(of: chief, in: home)
        let file = brain.muxHome.appendingPathComponent("optchat/home-id")
        let home = home, app = app, resolve = environment
        return try? await work.run(.userBlocking, mayBlock: .files, {
            let pinned = Self.readPinnedID(at: file)
            let id = pinned ?? String(ChiefHome.tabHost(muxHome: brain.muxHome).dropFirst(ChiefHome.tabHostPrefix.count))
            var seen = Set<String>()
            return (id, [resolve(brain), resolve(home), app].compactMap { $0 }.filter { seen.insert($0.socketPath).inserted })
        })
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
