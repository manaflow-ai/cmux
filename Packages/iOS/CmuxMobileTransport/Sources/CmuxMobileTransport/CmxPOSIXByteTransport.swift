public import CMUXMobileCore
public import Foundation
import Dispatch

/// Errors raised while operating a ``CmxPOSIXByteTransport``.
public enum CmxPOSIXByteTransportError: Error, Equatable, Sendable {
    /// An operation was attempted before the accepted socket became ready.
    case notConnected
    /// The transport was already closed.
    case alreadyClosed
    /// A receive was requested while another is still in flight.
    case receiveAlreadyInProgress
    /// A send was requested while another is still in flight.
    case sendAlreadyInProgress
    /// A receive failed; the associated value describes the cause.
    case receiveFailed(String)
    /// A send failed; the associated value describes the cause.
    case sendFailed(String)
}

/// A ``CmxByteTransport`` over one already-connected POSIX socket.
///
/// The Mac pairing host accepts inbound TCP through a BSD listening socket
/// instead of a Network.framework `NWListener`, because on macOS 26/27 with
/// the Tailscale system extension the kernel drops inbound-delivered
/// connections whose listener is an NWListener socket before `accept` ever
/// runs. This transport carries the accepted file descriptor through the same
/// byte contract the NW-based transport implements, so `MobileHostConnection`
/// consumes both identically.
///
/// The actor owns the file descriptor, a private I/O queue, and every
/// in-flight continuation, so receive/send/close serialize without locks.
/// Readiness is driven by `DispatchSource` read and write events on the
/// descriptor, the sanctioned carve-out for low-level socket I/O. Sources are
/// created suspended and toggled with balanced `resume()`/`suspend()` guarded
/// by `readSourceResumed`/`writeSourceResumed`, so the dispatch suspension
/// count can never go negative. The descriptor is closed exactly once, on the
/// I/O queue, by the read source's cancel handler.
public actor CmxPOSIXByteTransport: CmxByteTransport {
    /// Default per-receive byte cap, matching ``CmxNetworkByteTransport``.
    public static let defaultMaximumReceiveLength = 64 * 1024

    private enum TransportState {
        case ready
        case failed(CmxPOSIXByteTransportError)
        case closed
    }

    private enum ReadOutcome: Sendable {
        case bytes(Data)
        case endOfStream
        case wouldBlock
        case failed(String)
    }

    private enum WriteOutcome: Sendable {
        case progress(Int)
        case wouldBlock
        case failed(String)
    }

    private let fileDescriptor: Int32
    private let ioQueue: DispatchQueue
    private let maximumReceiveLength: Int
    private var state: TransportState = .ready
    private var remoteDidClose = false
    private var receiveContinuation: (id: UUID, continuation: CheckedContinuation<Data?, any Error>)?
    private var cancelledReceiveIDs: Set<UUID> = []
    private var receiveBuffer: [Data] = []
    private var sendContinuation: (id: UUID, continuation: CheckedContinuation<Void, any Error>?)?
    private var cancelledSendIDs: Set<UUID> = []
    private var sendBuffer = Data()
    private var sendOffset = 0
    private let readSource: any DispatchSourceRead
    private let writeSource: any DispatchSourceWrite
    private var readSourceResumed = false
    private var writeSourceResumed = false
    /// Set by ``tearDown(pendingError:resumeReceiveWithError:)`` so ``deinit``
    /// can tell "already cancelled" from "never cleaned up".
    private var sourcesCancelled = false

    /// Wraps an accepted, connected socket.
    ///
    /// The transport takes ownership of `acceptedFileDescriptor`: it configures
    /// nothing itself (the acceptor sets `O_NONBLOCK`, `TCP_NODELAY`, and
    /// `SO_NOSIGPIPE`) and closes the descriptor exactly once on teardown.
    /// - Parameters:
    ///   - acceptedFileDescriptor: A connected, nonblocking socket descriptor.
    ///   - maximumReceiveLength: Positive per-receive byte cap.
    public init(
        acceptedFileDescriptor: Int32,
        maximumReceiveLength: Int = CmxPOSIXByteTransport.defaultMaximumReceiveLength
    ) {
        fileDescriptor = acceptedFileDescriptor
        ioQueue = DispatchQueue(
            label: "dev.cmux.mobile.posix-byte-transport.\(UUID().uuidString)"
        )
        self.maximumReceiveLength = maximumReceiveLength
        // Handlers attach after every stored property is initialized, so the
        // event closures may safely capture self.
        readSource = DispatchSource.makeReadSource(
            fileDescriptor: acceptedFileDescriptor,
            queue: ioQueue
        )
        writeSource = DispatchSource.makeWriteSource(
            fileDescriptor: acceptedFileDescriptor,
            queue: ioQueue
        )
        readSource.setEventHandler { [weak self] in
            guard let self else { return }
            let outcome = Self.readOnce(
                fileDescriptor: self.fileDescriptor,
                maximumLength: self.maximumReceiveLength
            )
            Task { await self.handleReadOutcome(outcome) }
        }
        readSource.setCancelHandler {
            Darwin.close(acceptedFileDescriptor)
        }
        writeSource.setEventHandler { [weak self] in
            guard let self else { return }
            Task { await self.pumpSend() }
        }
    }

    deinit {
        // A dispatch source released while suspended traps libdispatch, and a
        // source cancelled while suspended never runs its cancel handler (the
        // fd would leak). If teardown never ran (a caller dropped the transport
        // without close(), or the process is shutting down before a pending
        // close task runs), finish the same resume-then-cancel sequence here.
        guard !sourcesCancelled else { return }
        let readResumed = readSourceResumed
        let writeResumed = writeSourceResumed
        ioQueue.async { [readSource, writeSource] in
            if !writeResumed { writeSource.resume() }
            writeSource.cancel()
            if !readResumed { readSource.resume() }
            readSource.cancel()
        }
    }

    /// No-op for an accepted socket: the connection already exists.
    ///
    /// Validates the transport is still usable so callers that symmetrically
    /// `connect()` before use (as the NW transport requires) keep working.
    /// - Throws: ``CmxPOSIXByteTransportError/alreadyClosed`` after close, or
    ///   the recorded failure if the transport failed.
    public func connect() async throws {
        try Task.checkCancellation()
        switch state {
        case .ready:
            return
        case let .failed(error):
            throw error
        case .closed:
            throw CmxPOSIXByteTransportError.alreadyClosed
        }
    }

    /// Receives the next chunk of bytes, or `nil` at end of stream.
    /// - Returns: The next received `Data`, or `nil` once the peer closed.
    /// - Throws: ``CmxPOSIXByteTransportError`` or `CancellationError`.
    public func receive() async throws -> Data? {
        try Task.checkCancellation()
        let operationID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                Task {
                    await self.startReceive(
                        operationID: operationID,
                        continuation: continuation
                    )
                }
            }
        } onCancel: {
            Task { await self.cancelReceive(operationID: operationID) }
        }
    }

    /// Sends bytes over the socket. Empty data is a no-op.
    /// - Parameter data: The bytes to write.
    /// - Throws: ``CmxPOSIXByteTransportError`` or `CancellationError`.
    public func send(_ data: Data) async throws {
        guard !data.isEmpty else {
            return
        }
        try Task.checkCancellation()
        let operationID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                Task {
                    await self.startSend(
                        data,
                        operationID: operationID,
                        continuation: continuation
                    )
                }
            }
        } onCancel: {
            Task { await self.cancelSend(operationID: operationID) }
        }
    }

    /// Closes the socket and completes any in-flight operations.
    ///
    /// A pending ``receive()`` resolves to `nil` (end of stream); a pending
    /// ``send(_:)`` fails with ``CmxPOSIXByteTransportError/alreadyClosed``.
    public func close() async {
        tearDown(pendingError: CmxPOSIXByteTransportError.alreadyClosed, resumeReceiveWithError: false)
    }

    // MARK: - Receive path

    private func startReceive(
        operationID: UUID,
        continuation: CheckedContinuation<Data?, any Error>
    ) async {
        guard !consumeCancelledReceive(operationID) else {
            continuation.resume(throwing: CancellationError())
            return
        }
        switch state {
        case .ready:
            break
        case let .failed(error):
            continuation.resume(throwing: error)
            return
        case .closed:
            continuation.resume(returning: nil)
            return
        }

        if !receiveBuffer.isEmpty {
            continuation.resume(returning: receiveBuffer.removeFirst())
            return
        }
        guard !remoteDidClose else {
            continuation.resume(returning: nil)
            return
        }
        guard receiveContinuation == nil else {
            continuation.resume(throwing: CmxPOSIXByteTransportError.receiveAlreadyInProgress)
            return
        }

        receiveContinuation = (operationID, continuation)
        resumeReadSource()
    }

    private func handleReadOutcome(_ outcome: ReadOutcome) {
        switch outcome {
        case let .bytes(data):
            // A late event after teardown still lands here; drop it silently
            // rather than buffering data for a closed transport.
            guard !isTerminal else { return }
            if let pending = receiveContinuation {
                receiveContinuation = nil
                suspendReadSource()
                pending.continuation.resume(returning: data)
            } else {
                suspendReadSource()
                receiveBuffer.append(data)
            }
        case .endOfStream:
            remoteDidClose = true
            suspendReadSource()
            if let pending = receiveContinuation {
                receiveContinuation = nil
                pending.continuation.resume(returning: nil)
            }
        case .wouldBlock:
            // Spurious wakeup: leave the source resumed and the continuation
            // armed; the next readable event carries the payload.
            break
        case let .failed(description):
            guard !isTerminal else { return }
            failTransport(.receiveFailed(description))
        }
    }

    private func resumeReadSource() {
        // After teardown the source is cancelled; resuming or suspending a
        // cancelled source traps libdispatch, so every toggle is terminal-gated.
        guard !readSourceResumed, !isTerminal else { return }
        readSourceResumed = true
        readSource.resume()
    }

    private func suspendReadSource() {
        guard readSourceResumed, !isTerminal else { return }
        readSourceResumed = false
        readSource.suspend()
    }

    private func cancelReceive(operationID: UUID) {
        if let pending = receiveContinuation, pending.id == operationID {
            receiveContinuation = nil
            suspendReadSource()
            pending.continuation.resume(throwing: CancellationError())
        } else {
            cancelledReceiveIDs.insert(operationID)
        }
    }

    private func consumeCancelledReceive(_ operationID: UUID) -> Bool {
        cancelledReceiveIDs.remove(operationID) != nil
    }

    // MARK: - Send path

    private func startSend(
        _ data: Data,
        operationID: UUID,
        continuation: CheckedContinuation<Void, any Error>
    ) async {
        guard !consumeCancelledSend(operationID) else {
            continuation.resume(throwing: CancellationError())
            return
        }
        switch state {
        case .ready:
            break
        case let .failed(error):
            continuation.resume(throwing: error)
            return
        case .closed:
            continuation.resume(throwing: CmxPOSIXByteTransportError.alreadyClosed)
            return
        }
        guard sendContinuation == nil else {
            continuation.resume(throwing: CmxPOSIXByteTransportError.sendAlreadyInProgress)
            return
        }

        sendContinuation = (operationID, continuation)
        sendBuffer = data
        sendOffset = 0
        pumpSend()
    }

    /// Writes what the nonblocking socket accepts now, completing the send when
    /// the buffer drains or arming the write source on a would-block. Runs on
    /// the actor; `write` on the nonblocking descriptor returns immediately.
    private func pumpSend() {
        guard !isTerminal else { return }
        guard let pending = sendContinuation else { return }
        let remaining = sendBuffer.count - sendOffset
        guard remaining > 0 else {
            sendContinuation = nil
            suspendWriteSource()
            pending.continuation?.resume()
            return
        }

        var writeErrno: Int32 = 0
        let written = sendBuffer.withUnsafeBytes { rawBuffer -> Int in
            guard let base = rawBuffer.baseAddress else { return 0 }
            let byteCount = write(fileDescriptor, base + sendOffset, remaining)
            // Capture errno at the syscall site: any code between write()
            // returning and the capture can clobber the thread-local errno.
            if byteCount < 0 {
                writeErrno = errno
            }
            return byteCount
        }

        if written > 0 {
            sendOffset += written
            if sendOffset >= sendBuffer.count {
                sendContinuation = nil
                suspendWriteSource()
                pending.continuation?.resume()
            } else {
                // Partial write: the kernel buffer filled partway. Wait for
                // writability (the event fires immediately if space remains)
                // instead of spinning on write().
                resumeWriteSource()
            }
            return
        }
        if written == 0 {
            failTransport(.sendFailed("zero-length write"))
            return
        }

        switch writeErrno {
        case EAGAIN, EWOULDBLOCK, EINTR:
            resumeWriteSource()
        default:
            failTransport(.sendFailed(String(cString: strerror(writeErrno))))
        }
    }

    private func resumeWriteSource() {
        guard !writeSourceResumed, !isTerminal else { return }
        writeSourceResumed = true
        writeSource.resume()
    }

    private func suspendWriteSource() {
        guard writeSourceResumed, !isTerminal else { return }
        writeSourceResumed = false
        writeSource.suspend()
    }

    private func cancelSend(operationID: UUID) {
        if let pending = sendContinuation, pending.id == operationID {
            sendContinuation = nil
            cancelledSendIDs.insert(operationID)
            pending.continuation?.resume(throwing: CancellationError())
        } else {
            cancelledSendIDs.insert(operationID)
        }
    }

    private func consumeCancelledSend(_ operationID: UUID) -> Bool {
        cancelledSendIDs.remove(operationID) != nil
    }

    // MARK: - Teardown

    private func failTransport(_ error: CmxPOSIXByteTransportError) {
        guard !isTerminal else {
            return
        }
        state = .failed(error)
        tearDown(pendingError: error, resumeReceiveWithError: true)
    }

    private func tearDown(pendingError: any Error, resumeReceiveWithError: Bool) {
        guard !isClosedState else {
            return
        }
        state = .closed
        cancelledReceiveIDs.removeAll()
        cancelledSendIDs.removeAll()
        receiveBuffer.removeAll()

        // Cancel on the I/O queue so an in-flight read handler completes
        // first; the read source's cancel handler closes the descriptor
        // exactly once. Sources never resume after this point. A suspended
        // source must be resumed before cancel: a cancelled suspended source
        // never runs its cancel handler, and releasing it traps libdispatch.
        let readWasResumed = readSourceResumed
        let writeWasResumed = writeSourceResumed
        readSourceResumed = false
        writeSourceResumed = false
        sourcesCancelled = true
        ioQueue.async { [readSource, writeSource] in
            if !writeWasResumed { writeSource.resume() }
            writeSource.cancel()
            if !readWasResumed { readSource.resume() }
            readSource.cancel()
        }

        if let pending = receiveContinuation {
            receiveContinuation = nil
            if resumeReceiveWithError {
                pending.continuation.resume(throwing: pendingError)
            } else {
                pending.continuation.resume(returning: nil)
            }
        }
        if let pending = sendContinuation {
            sendContinuation = nil
            pending.continuation?.resume(throwing: pendingError)
        }
    }

    private var isTerminal: Bool {
        switch state {
        case .failed, .closed:
            return true
        case .ready:
            return false
        }
    }

    private var isClosedState: Bool {
        if case .closed = state {
            return true
        }
        return false
    }

    // MARK: - Syscall helpers

    /// Performs one `read` on the I/O queue, classifying the outcome while
    /// `errno` is still bound to the syscall.
    private nonisolated static func readOnce(
        fileDescriptor: Int32,
        maximumLength: Int
    ) -> ReadOutcome {
        var buffer = [UInt8](repeating: 0, count: maximumLength)
        let byteCount = read(fileDescriptor, &buffer, maximumLength)
        if byteCount > 0 {
            return .bytes(Data(buffer[0..<byteCount]))
        }
        if byteCount == 0 {
            return .endOfStream
        }
        let errnoValue = errno
        switch errnoValue {
        case EAGAIN, EWOULDBLOCK, EINTR:
            return .wouldBlock
        default:
            return .failed(String(cString: strerror(errnoValue)))
        }
    }

    private nonisolated static func makeReadSource(
        fileDescriptor: Int32,
        queue: DispatchQueue,
        handler: @escaping @Sendable () -> Void
    ) -> any DispatchSourceRead {
        let source = DispatchSource.makeReadSource(
            fileDescriptor: fileDescriptor,
            queue: queue
        )
        source.setEventHandler(handler: handler)
        source.setCancelHandler {
            Darwin.close(fileDescriptor)
        }
        return source
    }

    private nonisolated static func makeWriteSource(
        fileDescriptor: Int32,
        queue: DispatchQueue,
        handler: @escaping @Sendable () -> Void
    ) -> any DispatchSourceWrite {
        let source = DispatchSource.makeWriteSource(
            fileDescriptor: fileDescriptor,
            queue: queue
        )
        source.setEventHandler(handler: handler)
        return source
    }
}
