import CmuxAgentChat
import Foundation

/// Supplies deterministic artifact bytes while recording source fetches.
actor CountingContentSource {
    private let values: [String: Data]
    private var counts: [String: Int] = [:]

    init(values: [String: Data]) {
        self.values = values
    }

    func fetch(
        key: String,
        receive: @Sendable (ChatArtifactChunk) async throws -> Void
    ) async throws {
        let data = values[key] ?? Data()
        counts[key, default: 0] += 1
        try await receive(ChatArtifactChunk(
            data: data,
            offset: 0,
            totalSize: Int64(data.count),
            eof: true
        ))
    }

    func fetchCount(for key: String) -> Int {
        counts[key, default: 0]
    }
}
