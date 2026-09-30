import Foundation
import Synchronization

/// Reads the first newline-terminated line from a pipe on the handle's own
/// dispatch source (never the caller's thread). Cancelling the awaiting task
/// stops reading and throws `CancellationError`, so a deadline never leaves
/// the read behind.
nonisolated final class AgentPaneLineReader: Sendable {
    enum Failure: Error, Equatable {
        /// The writers closed the pipe before a full line.
        case endOfFile
        case lineTooLong
    }

    private struct State {
        var buffer = Data()
        var continuation: CheckedContinuation<String, any Error>?
        var outcome: Result<String, any Error>?
    }

    static let maximumLength = 64 * 1024

    private let handle: FileHandle
    private let state = Mutex(State())

    init(handle: FileHandle) {
        self.handle = handle
    }

    func firstLine() async throws -> String {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Reading starts before the continuation is stored: a line or a
                // cancel that lands in between is kept in `outcome` and resumed here.
                // concurrency-allow: readabilityHandler runs on the handle's own dispatch queue and data is already available
                handle.readabilityHandler = { [self] handle in receive(handle.availableData) }
                let early = state.withLock { state -> Result<String, any Error>? in
                    if state.outcome == nil { state.continuation = continuation }
                    return state.outcome
                }
                if let early {
                    handle.readabilityHandler = nil
                    continuation.resume(with: early)
                }
            }
        } onCancel: {
            finish(.failure(CancellationError()))
        }
    }

    /// Feeds bytes as the dispatch source delivers them; empty data is EOF.
    func receive(_ chunk: Data) {
        guard !chunk.isEmpty else { return finish(.failure(Failure.endOfFile)) }
        let line = state.withLock { state -> Result<String, any Error>? in
            state.buffer += chunk
            if let newline = state.buffer.firstIndex(of: 0x0A) {
                return .success(String(decoding: state.buffer[state.buffer.startIndex..<newline], as: UTF8.self))
            }
            return state.buffer.count > Self.maximumLength ? .failure(Failure.lineTooLong) : nil
        }
        if let line { finish(line) }
    }

    private func finish(_ outcome: Result<String, any Error>) {
        let continuation = state.withLock { state -> CheckedContinuation<String, any Error>? in
            guard state.outcome == nil else { return nil }
            state.outcome = outcome
            defer { state.continuation = nil }
            return state.continuation
        }
        handle.readabilityHandler = nil
        continuation?.resume(with: outcome)
    }
}
