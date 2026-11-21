import CMUXAgentLaunch
import Foundation

extension ClaudeAccountAutoSwitchCoordinator {
    /// The accounts other than the current one that have a Claude config, and those of them that
    /// already trust the session's folder. Runs off the main actor: `.claude.json` holds every
    /// project's history and can be large.
    #if compiler(>=6.2)
    @concurrent
    #else
    @Sendable
    #endif
    nonisolated static func candidateFacts(
        pane: ClaudeAccountAutoSwitchRequest.Pane,
        homeDirectory: String
    ) async -> (usable: Set<String>, trusted: Set<String>) {
        guard case .local(let current, let registry, let workingDirectory) = pane else { return ([], []) }
        let currentKey = current.exhaustionKey(homeDirectory: homeDirectory)
        var usable = Set<String>()
        var trusted = Set<String>()
        for account in registry.accounts where account.exhaustionKey(homeDirectory: homeDirectory) != currentKey
            && ClaudeConfigTrustReader.hasConfig(account: account, homeDirectory: homeDirectory) {
            let key = account.exhaustionKey(homeDirectory: homeDirectory)
            usable.insert(key)
            if let workingDirectory,
               ClaudeConfigTrustReader.isTrusted(workingDirectory: workingDirectory, account: account, homeDirectory: homeDirectory) {
                trusted.insert(key)
            }
        }
        return (usable, trusted)
    }
}
