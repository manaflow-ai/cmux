public import Foundation

/// Decodes the result of `mobile.workspace.changes.summary`.
public struct MobileChangesSummaryResponse: Codable, Sendable, Equatable {
    /// The baseline resolved by the Mac.
    public let baseInfo: MobileChangesBaseInfo
    /// Aggregate file and line counts.
    public let totals: MobileChangesTotals
    /// Changed-file summaries in host order.
    public let files: [MobileChangesFile]
    /// The number of changed files omitted by the host's summary cap.
    public let truncatedFileCount: Int

    /// Creates a changes summary response.
    /// - Parameters:
    ///   - baseInfo: The baseline resolved by the Mac.
    ///   - totals: Aggregate file and line counts.
    ///   - files: Changed-file summaries in host order.
    ///   - truncatedFileCount: The number of changed files omitted by the summary cap.
    public init(
        baseInfo: MobileChangesBaseInfo,
        totals: MobileChangesTotals,
        files: [MobileChangesFile],
        truncatedFileCount: Int
    ) {
        self.baseInfo = baseInfo
        self.totals = totals
        self.files = files
        self.truncatedFileCount = truncatedFileCount
    }

    private enum CodingKeys: String, CodingKey {
        case baseInfo = "base_info"
        case totals
        case files
        case truncatedFileCount = "truncated_file_count"
    }

    /// Decodes a summary response from an RPC result payload.
    /// - Parameter data: The JSON result payload.
    /// - Returns: The decoded response.
    /// - Throws: A decoding error if the payload is malformed.
    public static func decode(_ data: Data) throws -> MobileChangesSummaryResponse {
        try JSONDecoder().decode(Self.self, from: data)
    }
}
