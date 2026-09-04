struct WorkspaceLinksIngestConfiguration: Equatable, Sendable {
    static let maximumRetentionLimit = 10_000

    var includeFilePaths: Bool
    var ignoreHosts: [String]
    var retentionLimit: Int

    init(
        includeFilePaths: Bool = false,
        ignoreHosts: [String] = ["localhost:31034"],
        retentionLimit: Int = 500
    ) {
        self.includeFilePaths = includeFilePaths
        self.ignoreHosts = ignoreHosts
        self.retentionLimit = Self.clampedRetentionLimit(retentionLimit)
    }

    static func clampedRetentionLimit(_ value: Int) -> Int {
        min(max(value, 10), maximumRetentionLimit)
    }
}
