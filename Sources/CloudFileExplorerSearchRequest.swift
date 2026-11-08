import Foundation

/// One queued Cloud search and its waiting UI continuation.
struct CloudFileExplorerSearchRequest {
    typealias Operation = @Sendable () async throws -> FileSearchSnapshot

    let id: UUID
    let operation: Operation
    var continuation: CheckedContinuation<FileSearchSnapshot, Error>?
}
