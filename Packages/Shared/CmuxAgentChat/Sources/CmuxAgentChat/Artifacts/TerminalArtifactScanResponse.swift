/// One file-like path detected in terminal output.
public struct TerminalArtifactReference: Sendable, Equatable, Codable, Identifiable {
    /// Absolute path to request from the Mac.
    public let path: String
    /// The artifact preview category.
    public let kind: ChatArtifactKind
    /// Basename shown in terminal artifact lists.
    public let displayName: String

    /// Stable identity for SwiftUI lists.
    public var id: String { path }

    /// Creates a terminal artifact reference.
    public init(path: String, kind: ChatArtifactKind, displayName: String) {
        self.path = path
        self.kind = kind
        self.displayName = displayName
    }

    private enum CodingKeys: String, CodingKey {
        case path
        case kind
        case displayName = "display_name"
    }
}

/// Response for `mobile.terminal.artifact.scan`.
public struct TerminalArtifactScanResponse: Sendable, Equatable, Codable {
    /// Capped terminal artifacts sorted by detection order.
    public let artifacts: [TerminalArtifactReference]

    /// Creates a scan response.
    public init(artifacts: [TerminalArtifactReference]) {
        self.artifacts = artifacts
    }
}
