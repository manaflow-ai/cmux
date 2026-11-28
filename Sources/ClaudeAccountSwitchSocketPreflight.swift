import CMUXAgentLaunch
import Foundation

/// The checks `claude_account.switch` makes before it runs the shared switch, in order: an
/// unknown account, a pane on another machine, then a running response without `force`. A
/// switch that can never happen is refused before the caller is asked to stop a response, so
/// `agent_running` (and its `--force` hint) only comes back for a switch that would really go
/// ahead: where the pane's cached account already is the target, that answer is `same_account`.
/// The cached account trails a switch by a few seconds, so it decides nothing else; the shared
/// switch refuses the pane's own account from a fresh read. The result codes are the shared
/// switch's own. A session with no conversation yet is left to the shared switch, which reads
/// its transcript: such a session cannot be mid-response, so it never gets `agent_running` first.
struct ClaudeAccountSwitchSocketPreflight {
    /// The account the request asked for.
    let accountName: String
    /// That account in the pane's registry, or `nil` when no account has the name.
    let target: ClaudeAccount?
    /// The account the pane's cached Claude session runs under, or `nil` with no cached session.
    let current: ClaudeAccount?
    let runsOnAnotherMachine: Bool
    let responseRunning: Bool
    let force: Bool
    let homeDirectory: String

    /// The refusal to answer with, or `nil` to run the switch. The switch repeats the
    /// remote and same-account checks against authoritative state.
    var refusal: ClaudeAccountSwitchSocketOutcome? {
        guard let target else { return .finished(.refused(.unknownAccount(accountName))) }
        if runsOnAnotherMachine { return .finished(.remoteUnsupported) }
        guard responseRunning, !force else { return nil }
        if let current,
           current.exhaustionKey(homeDirectory: homeDirectory) == target.exhaustionKey(homeDirectory: homeDirectory) {
            return .finished(.refused(.sameAccount(accountName)))
        }
        return .agentRunning
    }
}
