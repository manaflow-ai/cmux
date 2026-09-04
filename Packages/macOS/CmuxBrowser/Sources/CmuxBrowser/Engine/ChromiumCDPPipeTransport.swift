import Darwin
import Foundation

/// Null-delimited CDP over inherited descriptors, with bounded buffering and
/// cancellable kernel I/O that never parks a cooperative executor thread.
actor ChromiumCDPPipeTransport: ChromiumCDPTransport {
    private static let maximumMessageBytes = 32 * 1024 * 1024
    private let input: ChromiumPipeIO
    private let output: ChromiumPipeIO
    private let messageStream: AsyncStream<Result<Data, CDPError>>
    private let continuation: AsyncStream<Result<Data, CDPError>>.Continuation
    private var reader: Task<Void, Never>?
    private var closed = false
    private var writesInFlight = 0

    init(commandDescriptor: Int32, responseDescriptor: Int32) throws {
        guard fcntl(commandDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            Darwin.close(commandDescriptor)
            Darwin.close(responseDescriptor)
            throw error
        }
        input = ChromiumPipeIO(descriptor: commandDescriptor)
        output = ChromiumPipeIO(descriptor: responseDescriptor)
        let pair = AsyncStream<Result<Data, CDPError>>.makeStream(bufferingPolicy: .bufferingOldest(64))
        messageStream = pair.stream
        continuation = pair.continuation
    }

    deinit {
        reader?.cancel()
        input.close()
        output.close()
        continuation.finish()
    }

    func connect() {
        guard reader == nil, !closed else { return }
        let chunks = output.chunks()
        let continuation = continuation
        reader = Task { [weak self] in
            var pending = Data()
            do {
                for try await chunk in chunks {
                    try Task.checkCancellation()
                    pending.append(chunk)
                    while let delimiter = pending.firstIndex(of: 0) {
                        guard pending.distance(from: pending.startIndex, to: delimiter) <= Self.maximumMessageBytes else {
                            throw CDPError.malformedMessage
                        }
                        if case .dropped = continuation.yield(.success(Data(pending[..<delimiter]))) {
                            throw CDPError.malformedMessage
                        }
                        pending.removeSubrange(...delimiter)
                    }
                    guard pending.count <= Self.maximumMessageBytes else { throw CDPError.malformedMessage }
                }
                if !pending.isEmpty { throw CDPError.malformedMessage }
            } catch {
                continuation.yield(.failure(.disconnected(error.localizedDescription)))
            }
            continuation.finish()
            await self?.close()
        }
    }

    nonisolated func messages() -> AsyncStream<Result<Data, CDPError>> { messageStream }

    func send(_ data: Data) async throws {
        guard !closed else { throw CDPError.notConnected }
        guard data.count <= Self.maximumMessageBytes else { throw CDPError.malformedMessage }
        guard writesInFlight < 128 else { throw CDPError.commandFailed(ChromiumBrowserDiagnostic.commandQueueFull.message) }
        writesInFlight += 1
        defer { writesInFlight -= 1 }
        var framed = data
        framed.append(0)
        try await input.write(framed)
    }

    func close() {
        guard !closed else { return }
        closed = true
        reader?.cancel()
        reader = nil
        input.close()
        output.close()
        continuation.finish()
    }
}
