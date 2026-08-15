import Darwin
import Foundation

/// Null-delimited CDP transport over Chromium's private inherited descriptors.
actor ChromiumCDPPipeTransport: ChromiumCDPTransport {
    private static let maximumMessageBytes = 100 * 1024 * 1024

    private struct PendingWrite {
        let data: Data
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let commandDescriptor: Int32
    private let messageStream: AsyncStream<Result<Data, CDPError>>
    private let messageContinuation: AsyncStream<Result<Data, CDPError>>.Continuation
    private var pendingWrites: [PendingWrite] = []
    private var activeWrite: PendingWrite?
    private var isClosed = false
    private var commandDescriptorIsClosed = false

    init(commandDescriptor: Int32, responseDescriptor: Int32) throws {
        guard Darwin.fcntl(commandDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            let error = Self.posixError(errno)
            Darwin.close(commandDescriptor)
            Darwin.close(responseDescriptor)
            throw error
        }
        self.commandDescriptor = commandDescriptor
        let pair = AsyncStream<Result<Data, CDPError>>.makeStream()
        self.messageStream = pair.stream
        self.messageContinuation = pair.continuation

        // Chromium's response descriptor has no async-native Foundation API.
        // A detached task owns the raw descriptor and closes it after EOF.
        Task.detached {
            Self.readMessages(
                descriptor: responseDescriptor,
                continuation: pair.continuation
            )
        }
    }

    deinit {
        if !commandDescriptorIsClosed {
            Darwin.close(commandDescriptor)
        }
        messageContinuation.finish()
    }

    func connect() {}

    nonisolated func messages() -> AsyncStream<Result<Data, CDPError>> {
        messageStream
    }

    func send(_ data: Data) async throws {
        guard !isClosed else { throw CDPError.notConnected }
        var framed = data
        framed.append(0)
        try await withCheckedThrowingContinuation { continuation in
            pendingWrites.append(PendingWrite(data: framed, continuation: continuation))
            beginNextWriteIfNeeded()
        }
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        let queued = pendingWrites
        pendingWrites.removeAll()
        for write in queued {
            write.continuation.resume(
                throwing: CDPError.disconnected(ChromiumBrowserDiagnostic.connectionClosed.message)
            )
        }
        closeCommandDescriptorIfIdle()
        messageContinuation.finish()
    }

    private func beginNextWriteIfNeeded() {
        guard activeWrite == nil, !pendingWrites.isEmpty else {
            closeCommandDescriptorIfIdle()
            return
        }
        let write = pendingWrites.removeFirst()
        activeWrite = write
        let descriptor = commandDescriptor
        Task.detached { [self] in
            let result = Result {
                try Self.writeAll(write.data, to: descriptor)
            }
            await writeFinished(result)
        }
    }

    private func writeFinished(_ result: Result<Void, any Error>) {
        guard let write = activeWrite else { return }
        activeWrite = nil
        write.continuation.resume(with: result)
        if case .failure = result {
            isClosed = true
            let queued = pendingWrites
            pendingWrites.removeAll()
            for pendingWrite in queued {
                pendingWrite.continuation.resume(
                    throwing: CDPError.disconnected(ChromiumBrowserDiagnostic.connectionClosed.message)
                )
            }
        }
        beginNextWriteIfNeeded()
    }

    private func closeCommandDescriptorIfIdle() {
        guard isClosed, activeWrite == nil, !commandDescriptorIsClosed else { return }
        Darwin.close(commandDescriptor)
        commandDescriptorIsClosed = true
    }

    /// Performs only blocking POSIX reads against a raw, Sendable descriptor.
    private static func readMessages(
        descriptor: Int32,
        continuation: AsyncStream<Result<Data, CDPError>>.Continuation
    ) {
        defer {
            Darwin.close(descriptor)
            continuation.finish()
        }
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)

        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count > 0 {
                pending.append(contentsOf: buffer.prefix(count))
                while let delimiter = pending.firstIndex(of: 0) {
                    continuation.yield(.success(Data(pending[..<delimiter])))
                    pending.removeSubrange(...delimiter)
                }
                if pending.count > maximumMessageBytes {
                    continuation.yield(.failure(.malformedMessage))
                    return
                }
                continue
            }
            if count < 0, errno == EINTR { continue }
            if count < 0 {
                continuation.yield(.failure(posixError(errno)))
            } else if !pending.isEmpty {
                continuation.yield(.failure(.malformedMessage))
            }
            return
        }
    }

    /// Performs only blocking POSIX writes against the dedicated raw descriptor.
    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if count > 0 {
                    offset += count
                    continue
                }
                if count < 0, errno == EINTR { continue }
                throw posixError(errno)
            }
        }
    }

    private static func posixError(_ code: Int32) -> CDPError {
        .disconnected(NSError(domain: NSPOSIXErrorDomain, code: Int(code)).localizedDescription)
    }
}
