import CmuxFoundation

// App adapters from a Vault `SessionEntry` to the package's exclusion matcher.

extension SessionEntry {
    var vaultExclusionFields: CmuxVaultSessionFields {
        CmuxVaultSessionFields(
            agentID: agent.rawValue,
            agentName: agent.displayName,
            folder: cwd,
            entrypoint: entrypoint,
            label: title
        )
    }
}

extension CmuxVaultSessionExclusion {
    func matches(_ entry: SessionEntry) -> Bool {
        matches(entry.vaultExclusionFields)
    }

    func applies(to agent: SessionAgent) -> Bool {
        applies(toAgentID: agent.rawValue, agentName: agent.displayName)
    }
}

extension CmuxVaultSessionExclusionMatcher {
    func matches(_ entry: SessionEntry) -> Bool {
        matches(entry.vaultExclusionFields)
    }
}
