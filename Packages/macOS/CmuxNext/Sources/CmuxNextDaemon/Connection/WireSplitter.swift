import Darwin
import Foundation

/// Splits a daemon connection's byte stream into messages: JSON lines and
/// binary attach frames (`attach-frames-v1`, ``AttachFrameHeader``).
///
/// A message that starts with `0xFF` is a frame: its header names the
/// payload length, so the payload is read whole and never searched for a
/// newline. Anything else is a JSON line, and each byte of it is searched for
/// the newline once (the ``LineSplitter`` bound: a 10 MiB replay line must not
/// be rescanned per read). `scannedBytes` counts that search work, so tests
/// check the linear bound without timing it.
nonisolated struct WireSplitter {
    enum Message: Equatable {
        /// One JSON line, without its newline.
        case line(Data)
        case frame(AttachFrameHeader, Data)
    }

    /// The unfinished line, or the start of an unfinished frame header.
    private(set) var pending = Data()
    /// A frame whose payload is still arriving.
    private var frame: (header: AttachFrameHeader, payload: Data)?
    /// Bytes searched for a newline so far.
    private(set) var scannedBytes = 0

    /// Bytes held for an unfinished message (the reader's line-size bound).
    var bufferedBytes: Int { pending.count + (frame?.payload.count ?? 0) }

    /// Appends `bytes` and passes each complete message to `emit`, in order.
    /// Empty lines are skipped. Throws when a frame header is malformed; the
    /// stream cannot be resynchronized after that.
    mutating func append(_ bytes: UnsafeRawBufferPointer, emit: (Message) -> Void) throws(AttachFrameHeader.DecodeError) {
        guard let base = bytes.baseAddress else { return }
        var index = 0
        let count = bytes.count
        while index < count {
            if var arriving = frame {
                let take = min(arriving.header.length - arriving.payload.count, count - index)
                arriving.payload.append(base.advanced(by: index).assumingMemoryBound(to: UInt8.self), count: take)
                index += take
                if arriving.payload.count == arriving.header.length {
                    frame = nil
                    emit(.frame(arriving.header, arriving.payload))
                } else {
                    frame = arriving
                }
                continue
            }
            if pending.first == AttachFrameHeader.magic || (pending.isEmpty && bytes[checked: index] == AttachFrameHeader.magic) {
                let need = AttachFrameHeader.size - pending.count
                if pending.isEmpty, count - index >= AttachFrameHeader.size {
                    let header = try AttachFrameHeader(bytes.dropFirst(index).prefix(AttachFrameHeader.size))
                    index += AttachFrameHeader.size
                    start(header, emit: emit)
                    continue
                }
                let take = min(need, count - index)
                pending.append(base.advanced(by: index).assumingMemoryBound(to: UInt8.self), count: take)
                index += take
                guard pending.count == AttachFrameHeader.size else { continue }
                let header = try AttachFrameHeader(pending)
                pending.removeAll(keepingCapacity: true)
                start(header, emit: emit)
                continue
            }
            let rest = count - index
            guard let hit = memchr(base + index, 0x0A, rest) else {
                scannedBytes += rest
                pending.append(base.advanced(by: index).assumingMemoryBound(to: UInt8.self), count: rest)
                return
            }
            let end = base.distance(to: UnsafeRawPointer(hit))
            scannedBytes += end - index + 1
            if pending.isEmpty {
                if end > index { emit(.line(Data(bytes: base + index, count: end - index))) }
            } else {
                pending.append(base.advanced(by: index).assumingMemoryBound(to: UInt8.self), count: end - index)
                let line = pending
                pending = Data()
                emit(.line(line))
            }
            index = end + 1
        }
    }

    /// Begins `header`'s frame; an empty payload is complete at once.
    private mutating func start(_ header: AttachFrameHeader, emit: (Message) -> Void) {
        if header.length == 0 {
            emit(.frame(header, Data()))
        } else {
            var payload = Data()
            payload.reserveCapacity(header.length)
            frame = (header, payload)
        }
    }
}
