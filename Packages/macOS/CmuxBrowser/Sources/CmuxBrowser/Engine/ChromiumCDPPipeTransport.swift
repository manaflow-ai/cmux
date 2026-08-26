import Darwin
import Foundation

/// Null-delimited CDP transport over Chromium's private inherited descriptors.
actor ChromiumCDPPipeTransport: ChromiumCDPTransport {
    private static let maximumMessageBytes = 100 * 1024 * 1024
    private static let writeDeadline: Duration = .seconds(15)

    private struct PendingWrite {
        let data: Data
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let commandDescriptor: Int32
    private let messageStream: AsyncStream<Result<Data, CDPError>>
    private let messageContinuation: AsyncStream<Result<Data, CDPError>>.Continuation
    private let responseReadSource: ChromiumPipeReadSource
    private var pendingWrites: [PendingWrite] = []
    private var activeWrite: PendingWrite?
    private var activeWriteTimeoutTask: Task<Void, Never>?
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

        let readBuffer = ChromiumPipeReadBuffer(
            delimiter: 0,
            maximumPendingBytes: Self.maximumMessageBytes
        )
        do {
            self.responseReadSource = try ChromiumPipeReadSource(
                descriptor: responseDescriptor,
                label: "com.cmux.chromium.cdp-pipe-reader"
            ) {
                readBuffer.read(
                    from: responseDescriptor,
                    onMessage: { message in
                        pair.continuation.yield(.success(message))
                    },
                    onEnd: { hasPartialMessage, errorCode in
                        if hasPartialMessage {
                            pair.continuation.yield(.failure(.malformedMessage))
                        } else if let errorCode {
                            pair.continuation.yield(.failure(Self.posixError(errorCode)))
                        }
                        pair.continuation.finish()
                    }
                )
            }
        } catch {
            Darwin.close(commandDescriptor)
            throw error
        }
    }

    deinit {
        activeWriteTimeoutTask?.cancel()
        responseReadSource.cancel()
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
        activeWriteTimeoutTask?.cancel()
        activeWriteTimeoutTask = nil
        if let activeWrite {
            self.activeWrite = nil
            activeWrite.continuation.resume(
                throwing: CDPError.disconnected(ChromiumBrowserDiagnostic.connectionClosed.message)
            )
        }
        responseReadSource.cancel()
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
        activeWriteTimeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.writeDeadline)
            } catch {
                return
            }
            await self?.activeWriteTimedOut()
        }
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
        activeWriteTimeoutTask?.cancel()
        activeWriteTimeoutTask = nil
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

    private func activeWriteTimedOut() {
        guard let write = activeWrite else { return }
        activeWrite = nil
        activeWriteTimeoutTask = nil
        isClosed = true
        write.continuation.resume(throwing: ChromiumBrowserDiagnostic.commandTimedOut)
        let queued = pendingWrites
        pendingWrites.removeAll()
        for pendingWrite in queued {
            pendingWrite.continuation.resume(
                throwing: CDPError.disconnected(ChromiumBrowserDiagnostic.connectionClosed.message)
            )
        }
        closeCommandDescriptorIfIdle()
        messageContinuation.finish()
    }

    private func closeCommandDescriptorIfIdle() {
        guard isClosed, activeWrite == nil, !commandDescriptorIsClosed else { return }
        Darwin.close(commandDescriptor)
        commandDescriptorIsClosed = true
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
