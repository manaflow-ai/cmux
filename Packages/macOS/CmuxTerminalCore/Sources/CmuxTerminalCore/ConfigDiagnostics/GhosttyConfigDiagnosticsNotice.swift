/// The content of the notice cmux shows when the Ghostty config has errors.
public struct GhosttyConfigDiagnosticsNotice: Equatable, Sendable {
    /// The diagnostics to list, at most
    /// ``GhosttyConfigDiagnosticsNoticePolicy/maximumListedDiagnostics``.
    public let listedDiagnostics: [GhosttyConfigDiagnostic]
    /// The number of distinct user-facing diagnostics, including unlisted ones.
    public let totalCount: Int

    /// Creates a notice.
    ///
    /// - Parameters:
    ///   - listedDiagnostics: The diagnostics shown in the notice.
    ///   - totalCount: The number of distinct diagnostics.
    public init(listedDiagnostics: [GhosttyConfigDiagnostic], totalCount: Int) {
        self.listedDiagnostics = listedDiagnostics
        self.totalCount = totalCount
    }

    /// How many diagnostics exist beyond the listed ones.
    public var unlistedCount: Int {
        max(0, totalCount - listedDiagnostics.count)
    }

    /// The first file a diagnostic points at, for an "Open Config" action.
    public var firstFilePath: String? {
        listedDiagnostics.lazy.compactMap(\.filePath).first
    }
}
