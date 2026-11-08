import Foundation

/// One file-like path detected in terminal output.
public struct TerminalArtifactReference: Sendable, Equatable, Codable, Identifiable {
    /// Absolute path to request from the Mac.
    public let path: String
    /// The artifact preview category.
    public let kind: ChatArtifactKind
    /// Basename shown in terminal artifact lists.
    public let displayName: String
    /// Raw byte size when supplied by the scanning host.
    public let size: Int64?
    /// Last modification time when supplied by the scanning host.
    public let modifiedAt: Date?

    /// Stable identity for SwiftUI lists.
    public var id: String { path }

    /// Creates a terminal artifact reference.
    /// - Parameters:
    ///   - path: Absolute path to request from the Mac.
    ///   - kind: Artifact preview category.
    ///   - displayName: Basename shown in artifact lists.
    ///   - size: Raw byte size, when available.
    ///   - modifiedAt: Last modification time, when available.
    public init(
        path: String,
        kind: ChatArtifactKind,
        displayName: String,
        size: Int64? = nil,
        modifiedAt: Date? = nil
    ) {
        self.path = path
        self.kind = kind
        self.displayName = displayName
        self.size = size
        self.modifiedAt = modifiedAt
    }

    private enum CodingKeys: String, CodingKey {
        case path
        case kind
        case displayName = "display_name"
        case size
        case modifiedAt = "modified_at"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        kind = try container.decode(ChatArtifactKind.self, forKey: .kind)
        displayName = try container.decode(String.self, forKey: .displayName)
        size = try? container.decode(Int64.self, forKey: .size)
        if let seconds = try? container.decode(Double.self, forKey: .modifiedAt) {
            modifiedAt = Date(timeIntervalSince1970: seconds)
        } else {
            modifiedAt = try? container.decode(Date.self, forKey: .modifiedAt)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(path, forKey: .path)
        try container.encode(kind, forKey: .kind)
        try container.encode(displayName, forKey: .displayName)
        try container.encodeIfPresent(size, forKey: .size)
        if let modifiedAt {
            try container.encode(modifiedAt.timeIntervalSince1970, forKey: .modifiedAt)
        }
    }
}

/// Response for `mobile.terminal.artifact.scan`.
public struct TerminalArtifactScanResponse: Sendable, Equatable, Codable {
    /// Capped terminal artifacts sorted by detection order.
    public let artifacts: [TerminalArtifactReference]
    /// Agent session currently or most recently bound to the terminal, when supported.
    public let sessionID: String?
    /// Complete Session-tab artifact count, present for supported count-only scans.
    public let sessionArtifactTotal: Int?
    /// Rows rendered by the files sheet's default landing view, when supported.
    public let galleryRowTotal: Int?

    /// Creates a scan response.
    /// - Parameters:
    ///   - artifacts: Capped terminal artifacts sorted by detection order.
    ///   - sessionID: Agent session bound to the terminal, when available.
    ///   - sessionArtifactTotal: Complete Session-tab count for a count-only scan.
    ///   - galleryRowTotal: Rows in the files sheet's default landing view.
    public init(
        artifacts: [TerminalArtifactReference],
        sessionID: String? = nil,
        sessionArtifactTotal: Int? = nil,
        galleryRowTotal: Int? = nil
    ) {
        self.artifacts = artifacts
        self.sessionID = sessionID
        self.sessionArtifactTotal = sessionArtifactTotal
        self.galleryRowTotal = galleryRowTotal
    }

    /// Creates the lightweight response for a session-scoped count scan.
    ///
    /// This intentionally carries no page items and does not touch the
    /// filesystem; absent paths therefore count exactly as they do in the
    /// Session tab.
    ///
    /// - Parameters:
    ///   - sessionID: Agent session bound to the terminal.
    ///   - sessionArtifacts: Transcript-index snapshot used by the gallery.
    ///   - galleryRowTotal: Stat-filtered rows in the gallery's default view.
    /// - Returns: A count-only terminal scan response.
    public static func sessionCount(
        sessionID: String,
        sessionArtifacts: [ChatArtifactIndexedReference],
        galleryRowTotal: Int?
    ) -> TerminalArtifactScanResponse {
        TerminalArtifactScanResponse(
            artifacts: [],
            sessionID: sessionID,
            sessionArtifactTotal: ChatArtifactGalleryOrdering().sessionTotal(sessionArtifacts),
            galleryRowTotal: galleryRowTotal
        )
    }

    private enum CodingKeys: String, CodingKey {
        case artifacts
        case sessionID = "session_id"
        case sessionArtifactTotal = "session_artifact_total"
        case galleryRowTotal = "gallery_row_total"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        artifacts = (try? container.decode([TerminalArtifactReference].self, forKey: .artifacts)) ?? []
        sessionID = try? container.decode(String.self, forKey: .sessionID)
        sessionArtifactTotal = try? container.decode(Int.self, forKey: .sessionArtifactTotal)
        galleryRowTotal = try? container.decode(Int.self, forKey: .galleryRowTotal)
    }
}
