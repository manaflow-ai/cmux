import CmuxSettings

struct ClaudeVaultConfiguration: Sendable, Equatable {
    let extraSessionRoots: [String]
    let pathMappings: [VaultPathMapping]

    func merging(registry: CmuxVaultAgentRegistry) -> ClaudeVaultConfiguration {
        ClaudeVaultConfiguration(
            extraSessionRoots: Self.unique(extraSessionRoots + registry.claudeSessionRoots),
            pathMappings: Self.unique(pathMappings + registry.pathMappings)
        )
    }

    private static func unique<Value: Hashable>(_ values: [Value]) -> [Value] {
        var seen = Set<Value>()
        return values.filter { seen.insert($0).inserted }
    }
}
