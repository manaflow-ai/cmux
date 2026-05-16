import CMUXWorkstream

enum FeedPermissionActionPolicy {
    static func supportsPersistentPermissionModes(source: WorkstreamSource) -> Bool {
        source != .codex && source != .grok && source != .hermesAgent
    }

    static func supportsBypassPermissions(source: WorkstreamSource) -> Bool {
        source != .codex && source != .claude && source != .grok && source != .hermesAgent
    }
}
