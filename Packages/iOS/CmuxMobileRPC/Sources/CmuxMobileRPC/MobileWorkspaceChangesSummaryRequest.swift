public import Foundation

/// Additive request fields for `mobile.workspace.changes.summary`.
public struct MobileWorkspaceChangesSummaryRequest: Codable, Equatable, Sendable {
    /// Mac-local workspace identifiers included in the summary batch.
    public let workspaceIDs: [String]

    /// Whether the host should bypass its repository-root summary cache.
    public let force: Bool

    /// Creates a summary request.
    ///
    /// - Parameters:
    ///   - workspaceIDs: Between one and 64 Mac-local workspace identifiers.
    ///   - force: Whether the host should bypass its summary cache.
    /// - Returns: A request, or `nil` when the batch size is invalid.
    public init?(workspaceIDs: [String], force: Bool = false) {
        guard (1...64).contains(workspaceIDs.count) else { return nil }
        self.workspaceIDs = workspaceIDs
        self.force = force
    }

    /// Decodes a summary request, defaulting an absent additive `force` field to `false`.
    ///
    /// - Parameter data: Raw JSON request parameters.
    /// - Returns: A validated summary request.
    /// - Throws: ``DecodingError/dataCorrupted(_:)`` for an invalid batch.
    public static func decode(_ data: Data) throws -> Self {
        try JSONDecoder().decode(Self.self, from: data)
    }

    private enum CodingKeys: String, CodingKey {
        case workspaceIDs = "workspace_ids"
        case force
    }

    /// Decodes and validates request parameters.
    ///
    /// - Parameter decoder: Decoder containing the request fields.
    /// - Throws: ``DecodingError/dataCorrupted(_:)`` for an invalid batch.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let workspaceIDs = try container.decode([String].self, forKey: .workspaceIDs)
        let force = try container.decodeIfPresent(Bool.self, forKey: .force) ?? false
        guard let request = Self(workspaceIDs: workspaceIDs, force: force) else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: container.codingPath,
                    debugDescription: "Summary request must contain between one and 64 workspaces."
                )
            )
        }
        self = request
    }
}
