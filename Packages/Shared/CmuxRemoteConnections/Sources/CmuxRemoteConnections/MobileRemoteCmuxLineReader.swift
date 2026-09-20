import Foundation

/// Serializes bounded byte-to-line decoding for the cmux JSON stream.
actor MobileRemoteCmuxLineReader {
    private var input = Data()
    private var finished: (any Error)?
    private var waiter: CheckedContinuation<Void, any Error>?
    private var sourceTask: Task<Void, Never>?

    init() {}

    func start(stream: AsyncThrowingStream<Data, any Error>) {
        sourceTask = Task { [weak self] in
            do {
                for try await chunk in stream { await self?.append(chunk) }
                await self?.finish(error: nil)
            } catch {
                await self?.finish(error: error)
            }
        }
    }

    deinit { sourceTask?.cancel() }

    func nextLine(maximumBytes: Int) async throws -> Data {
        while true {
            if let newline = input.firstIndex(of: 0x0A) {
                let line = input[..<newline]
                input.removeSubrange(...newline)
                if line.isEmpty { continue }
                guard line.count <= maximumBytes else {
                    throw MobileRemoteCmuxProtocolError.frameTooLarge
                }
                return Data(line)
            }
            guard input.count <= maximumBytes else {
                throw MobileRemoteCmuxProtocolError.frameTooLarge
            }
            if let finished { throw finished }
            try await withCheckedThrowingContinuation { continuation in
                waiter = continuation
            }
        }
    }

    private func append(_ chunk: Data) {
        input.append(chunk)
        waiter?.resume()
        waiter = nil
    }

    private func finish(error: (any Error)?) {
        finished = error ?? MobileRemoteCmuxProtocolError.unexpectedEOF
        waiter?.resume(throwing: finished!)
        waiter = nil
    }
}
