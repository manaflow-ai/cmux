import CMUXWorkstream

enum FeedPermissionActionPolicy {
    static func supportsPersistentPermissionModes(source: WorkstreamSource) -> Bool {
        source != .codex
    }

    static func supportsBypassPermissions(source: WorkstreamSource) -> Bool {
        source != .codex && source != .claude
    }
}
