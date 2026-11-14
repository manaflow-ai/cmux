public import Foundation
import CmuxNextDaemon

/// One Move to SSH Machine run: asks Rust (``CloudMoveTargetRules``) for the `acpmux session move`
/// call, runs it with this app's acpmux and the person's ssh, and says what came of it. The App
/// gives it the values it reads (the chat, this Mac's peers, the acpmux binary and environment)
/// and shows the chat where it went.
public nonisolated struct SSHChatMoveRun: Sendable {
    /// What came of the run.
    public enum Outcome: Sendable, Equatable {
        /// The chat moved: this Mac's acpmux names it `session` now (`PEER/ID` on a peer).
        case moved(session: String)
        /// Nothing ran: Rust's refusal code (`not_offered`, `unknown_peer`, `not_started`).
        case refused(code: String)
        /// It ran and did not move the chat: acpmux's words, empty when it said none.
        case failed(String)
    }

    /// A move pushes the branch and makes a worktree there before the chat goes: minutes, not seconds.
    public static let limit: Duration = .seconds(900)

    public let executable: URL
    public let environment: [String: String]

    public init(executable: URL, environment: [String: String]) {
        self.executable = executable
        self.environment = environment
    }

    public func run(_ chat: CloudMoveTargetRules.Chat, to target: String?, peers: [CloudMoveTargetRules.Peer]) async -> Outcome {
        let rules = CloudMoveTargetRules()
        let call: (args: [String], moved: String)
        switch rules.sshMove(chat, to: target, peers: peers) {
        case .failure(let refusal): return .refused(code: refusal.message)
        case .success(let made): call = made
        }
        guard let result = try? await ProcessRunner.run(executable: executable, arguments: call.args, environment: environment,
                                                        timeout: Self.limit, clock: ContinuousClock()) else { return .failed("") }
        if let failure = rules.sshMoveFailure(stdout: String(decoding: result.stdout, as: UTF8.self),
                                              stderr: String(decoding: result.stderr, as: UTF8.self), status: result.status) {
            return .failed(failure)
        }
        return .moved(session: call.moved)
    }
}
