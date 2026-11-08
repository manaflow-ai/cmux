/// Off-main projection of merged Vault entries into bounded UI snapshots.
struct SessionIndexEntryProjection: Sendable {
#if compiler(>=6.2)
    @concurrent
#else
    @Sendable
#endif
    nonisolated func directorySnapshot(
        cwd: String,
        entries: [SessionEntry],
        noFolderScope: Bool,
        errors: [String]
    ) async -> DirectorySnapshot {
        let scoped = noFolderScope
            ? entries.filter { ($0.cwd ?? "").isEmpty }
            : entries
        return DirectorySnapshot(
            cwd: cwd,
            entries: scoped.sorted { $0.modified > $1.modified },
            errors: errors
        )
    }

#if compiler(>=6.2)
    @concurrent
#else
    @Sendable
#endif
    nonisolated func page(
        entries: [SessionEntry],
        noFolderScope: Bool,
        offset: Int,
        limit: Int
    ) async -> [SessionEntry] {
        let scoped = noFolderScope
            ? entries.filter { ($0.cwd ?? "").isEmpty }
            : entries
        let sorted = scoped.sorted { $0.modified > $1.modified }
        return Array(sorted.dropFirst(offset).prefix(limit))
    }
}
