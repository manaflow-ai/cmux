import Darwin
import Foundation

/// Null-delimited CDP transport over Chromium's private inherited descriptors.
actor ChromiumCDPPipeTransport: ChromiumCDPTransport {
    private static let messageBufferCapacity = 512
    private static let maximumMessageBytes = 100 * 1024 * 1024
    private static let writeDeadline: Duration = .seconds(15)

    private struct PendingWrite {
        let data: Data
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let messageStream: AsyncStream<Result<Data, CDPError>>
    private let messageContinuation: AsyncStream<Result<Data, CDPError>>.Continuation
    private let responseReadSource: ChromiumPipeReadSource
    private let commandWriteQueue: DispatchQueue
    private let commandWriteChannel: DispatchIO
    private var pendingWrites: [PendingWrite] = []
    private var activeWrite: PendingWrite?
    private var activeWriteTimeoutTask: Task<Void, Never>?
    private var isClosed = false
    private var commandWriteChannelIsClosed = false

    init(commandDescriptor: Int32, responseDescriptor: Int32) throws {
        guard Darwin.fcntl(commandDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            let error = Self.posixError(errno)
            Darwin.close(commandDescriptor)
            Darwin.close(responseDescriptor)
            throw error
        }
        let commandFlags = Darwin.fcntl(commandDescriptor, F_GETFL)
        guard commandFlags >= 0,
              Darwin.fcntl(commandDescriptor, F_SETFL, commandFlags | O_NONBLOCK) == 0 else {
            let error = Self.posixError(errno)
            Darwin.close(commandDescriptor)
            Darwin.close(responseDescriptor)
            throw error
        }
        let pair = AsyncStream<Result<Data, CDPError>>.makeStream(
            bufferingPolicy: .bufferingOldest(Self.messageBufferCapacity)
        )
        self.messageStream = pair.stream
        self.messageContinuation = pair.continuation
        let writeQueue = DispatchQueue(label: "com.cmux.chromium.cdp-pipe-writer", qos: .userInitiated)
        self.commandWriteQueue = writeQueue
        self.commandWriteChannel = DispatchIO(
            type: .stream,
            fileDescriptor: commandDescriptor,
            queue: writeQueue
        ) { _ in
            Darwin.close(commandDescriptor)
        }

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
                    guard case .enqueued = pair.continuation.yield(.success(message)) else {
                        _ = pair.continuation.yield(
                            .failure(.disconnected(ChromiumBrowserDiagnostic.connectionClosed.message))
                        )
                        pair.continuation.finish()
                        return
                    }
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
            commandWriteChannel.close(flags: .stop)
            throw error
        }
    }

    deinit {
        activeWriteTimeoutTask?.cancel()
        responseReadSource.cancel()
        commandWriteChannel.close(flags: .stop)
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
        let dispatchData = write.data.withUnsafeBytes { bytes in
            DispatchData(bytes: bytes)
        }
        commandWriteChannel.write(
            offset: 0,
            data: dispatchData,
            queue: commandWriteQueue
        ) { [weak self] done, _, errorCode in
            guard done || errorCode != 0 else { return }
            let result: Result<Void, CDPError>
            if errorCode == 0 {
                result = .success(())
            } else {
                result = .failure(Self.posixError(errorCode))
            }
            Task { @Sendable [weak self, result] in
                await self?.writeFinished(result)
            }
        }
    }

    private func writeFinished(_ result: Result<Void, CDPError>) {
        guard let write = activeWrite else { return }
        activeWrite = nil
        activeWriteTimeoutTask?.cancel()
        activeWriteTimeoutTask = nil
        write.continuation.resume(with: result)
        if case .failure = result, !isClosed {
            isClosed = true
            let queued = pendingWrites
            pendingWrites.removeAll()
            for pendingWrite in queued {
                pendingWrite.continuation.resume(
                    throwing: CDPError.disconnected(ChromiumBrowserDiagnostic.connectionClosed.message)
                )
            }
        }
        closeCommandDescriptorIfIdle()
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
        commandWriteChannelIsClosed = true
        commandWriteChannel.close(flags: .stop)
        messageContinuation.finish()
    }

    private func closeCommandDescriptorIfIdle() {
        guard isClosed, activeWrite == nil, !commandWriteChannelIsClosed else { return }
        commandWriteChannelIsClosed = true
        commandWriteChannel.close(flags: .stop)
    }

    private static func posixError(_ code: Int32) -> CDPError {
        .disconnected(NSError(domain: NSPOSIXErrorDomain, code: Int(code)).localizedDescription)
    }
}
