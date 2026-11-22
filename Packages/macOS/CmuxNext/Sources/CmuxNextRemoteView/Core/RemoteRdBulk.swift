import CCmuxRdFFI
public import Foundation

/// The viewer's side of bulk upload flow control on the stream carrier (rd
/// change C5, cap `bulk`), implemented by the shared Rust core: queued
/// transfer bytes go out as at most one 64 KiB chunk per media frame
/// interval, never while a media frame waits for the carrier, and never
/// past the host's credit (`bulk_credit` control messages). Send bulk only
/// when welcome lists the `bulk` cap. No I/O, threads or timers inside; not
/// thread-safe: one actor owns an instance, like `RemoteRdCore`.
public nonisolated final class RemoteRdBulkSender {
    /// Bytes of queued, unsent upload data one sender holds.
    public static let maxQueuedBytes = Int(CMUX_RD_BULK_MAX_QUEUED)
    /// The largest framed chunk `popFrame` returns.
    static let frameMax = Int(CMUX_RD_BULK_FRAME_MAX)

    private let handle: OpaquePointer

    /// `intervalMicros`: the media frame interval (one chunk per interval).
    /// Nil for 0 or when the core cannot allocate.
    public init?(intervalMicros: UInt64) {
        guard let handle = cmux_rd_bulk_sender_new(intervalMicros) else { return nil }
        self.handle = handle
    }

    deinit {
        cmux_rd_bulk_sender_free(handle)
    }

    /// Queues a transfer's bytes. Throws `.invalid` for a transfer id already
    /// queued, `.full` past `maxQueuedBytes`.
    public func queue(transfer: UInt64, data: Data) throws(RemoteRdCoreError) {
        let code = data.withUnsafeBytes { raw in
            cmux_rd_bulk_sender_queue(handle, transfer, raw.baseAddress?.assumingMemoryBound(to: UInt8.self), raw.count)
        }
        _ = try RemoteRdCoreError.check(code)
    }

    /// Applies the host's credit for a transfer (credit only grows).
    public func credit(transfer: UInt64, offset: UInt64) throws(RemoteRdCoreError) {
        _ = try RemoteRdCoreError.check(cmux_rd_bulk_sender_on_credit(handle, transfer, offset))
    }

    /// Offers a control message payload (JSON). True when it was a
    /// `bulk_credit` and was applied; false for another message.
    @discardableResult
    public func receive(control json: Data) throws(RemoteRdCoreError) -> Bool {
        let code = json.withUnsafeBytes { raw in
            cmux_rd_bulk_sender_on_control(handle, raw.baseAddress?.assumingMemoryBound(to: UInt8.self), raw.count)
        }
        return try RemoteRdCoreError.check(code) == 1
    }

    /// Drops a queued transfer (the user cancelled it).
    public func cancel(transfer: UInt64) throws(RemoteRdCoreError) {
        _ = try RemoteRdCoreError.check(cmux_rd_bulk_sender_cancel(handle, transfer))
    }

    /// The next chunk as a stream frame (type 3) ready for the carrier, or
    /// nil when none may go now. `mediaWaiting`: a media frame waits for the
    /// carrier, so bulk holds back.
    public func popFrame(nowMicros: UInt64, mediaWaiting: Bool) throws(RemoteRdCoreError) -> Data? {
        var buffer = [UInt8](repeating: 0, count: Self.frameMax)
        var length = 0
        let code = buffer.withUnsafeMutableBufferPointer { out in
            cmux_rd_bulk_sender_pop_frame(handle, nowMicros, mediaWaiting, out.baseAddress, out.count, &length)
        }
        guard try RemoteRdCoreError.check(code) == 1 else { return nil }
        return Data(buffer[0..<length])
    }

    /// When `popFrame` can give a chunk next (0 when one is pending); nil
    /// when idle or waiting for credit (arm no timer).
    public var nextDeadlineMicros: UInt64? {
        let deadline = cmux_rd_bulk_sender_next_deadline_us(handle)
        return deadline == UInt64.max ? nil : deadline
    }

    /// Bytes of queued upload data not yet sent.
    public var queuedBytes: UInt64 { cmux_rd_bulk_sender_queued_bytes(handle) }
}

/// The viewer's side of bulk downloads (rd change C5): each bulk payload is
/// checked for order and credit, and the framed `bulk_credit` to send back
/// comes out when one is due. Not thread-safe; one actor owns an instance.
public nonisolated final class RemoteRdBulkReceiver {
    /// One accepted chunk and the credit message to send back, if due.
    public struct Accepted: Sendable, Hashable {
        public var transfer: UInt64
        public var offset: UInt64
        public var bytes: Data
        /// A framed `bulk_credit` control message: send it as is.
        public var credit: Data?
    }

    /// Transfers one receiver tracks at once (`finish` frees a slot).
    public static let maxTransfers = Int(CMUX_RD_BULK_MAX_TRANSFERS)
    private static let creditMax = Int(CMUX_RD_BULK_CREDIT_MAX)

    private let handle: OpaquePointer

    /// Nil only when the core cannot allocate.
    public init?() {
        guard let handle = cmux_rd_bulk_receiver_new() else { return nil }
        self.handle = handle
    }

    deinit {
        cmux_rd_bulk_receiver_free(handle)
    }

    /// Takes one bulk payload (a `.bulk` message of `RemoteRdCore`). Throws
    /// `.invalid` for bad bytes, a gap, an overlap, a chunk past the credit
    /// or a finished transfer (a protocol error: end the session), `.full`
    /// for a new transfer while `maxTransfers` are open.
    public func accept(_ payload: Data) throws(RemoteRdCoreError) -> Accepted {
        var chunk = CmuxRdBulkChunk()
        var credit = [UInt8](repeating: 0, count: Self.creditMax)
        var creditLength = 0
        var bytes = Data()
        let code = payload.withUnsafeBytes { raw in
            let code = credit.withUnsafeMutableBufferPointer { out in
                cmux_rd_bulk_receiver_accept(
                    handle, raw.baseAddress?.assumingMemoryBound(to: UInt8.self), raw.count,
                    &chunk, out.baseAddress, out.count, &creditLength
                )
            }
            // `chunk.bytes` points into `payload`: copy it while the buffer is live.
            if code >= 0, let start = chunk.bytes { bytes = Data(bytes: start, count: chunk.len) }
            return code
        }
        _ = try RemoteRdCoreError.check(code)
        return Accepted(
            transfer: chunk.transfer, offset: chunk.offset, bytes: bytes,
            credit: creditLength > 0 ? Data(credit[0..<creditLength]) : nil
        )
    }

    /// Ends a transfer (complete or cancelled): later chunks are refused.
    public func finish(transfer: UInt64) throws(RemoteRdCoreError) {
        _ = try RemoteRdCoreError.check(cmux_rd_bulk_receiver_finish(handle, transfer))
    }
}
