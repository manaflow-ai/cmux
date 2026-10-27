import Foundation

extension TerminalAttachFrameDecoder {
    /// A SNAPSHOT or REPLAY event whose chunks are still coming (cmux-tui `server/snapshot_frames.rs`): the
    /// connection's writer cut it at BULK_FRAME_MAX, a SNAPSHOT into SNAPSHOT_MORE frames and a REPLAY into
    /// REPLAY frames, all with its aux. The meta of the first chunk says where the event ends.
    struct PendingBulk: Sendable {
        /// The event's meta, decoded once.
        enum Meta: Sendable {
            case replay(TerminalVTStateWire)
            case snapshot(TerminalSnapshotWire)
        }

        enum Progress {
            /// More chunks are due.
            case waiting
            /// The lengths do not add up, or the meta does not decode.
            case malformed
            /// The whole event: its meta and its raw bytes (`data`, then a replay's `pending`).
            case complete(Meta, raw: Data)
        }

        let kind: TerminalAttachFrame.Kind
        let offset: UInt64
        private var chunks: [TerminalFrameBytes] = []
        private var received = 0
        private var meta: Meta?
        /// Where the raw bytes lie in the event's payload, once the meta is read.
        private var raw: Range<Int>?

        init(kind: TerminalAttachFrame.Kind, offset: UInt64) {
            self.kind = kind
            self.offset = offset
        }

        /// Whether `frame` is the next chunk of this event.
        func continues(with frame: TerminalAttachFrame) -> Bool {
            guard frame.offset == offset else { return false }
            return kind == .snapshot ? frame.kind == .snapshotMore : frame.kind == .replay
        }

        mutating func append(_ chunk: TerminalFrameBytes, decoder: WireDecoder) -> Progress {
            let cap = TerminalAttachFrameDecoder.maxBulkBytes
            guard received <= cap - chunk.count else { return .malformed }
            chunks.append(chunk)
            received += chunk.count
            if meta == nil {
                let prefix = TerminalAttachFrameDecoder.metaLengthBytes
                guard received >= prefix else { return .waiting }
                guard let word = TerminalFrameBytes(bytes(0 ..< prefix)).littleEndianUInt32(at: 0) else { return .malformed }
                let metaLength = Int(clamping: word)
                guard metaLength <= cap - prefix else { return .malformed }
                let metaEnd = prefix + metaLength
                guard received >= metaEnd else { return .waiting }
                guard let parsed = decodeMeta(bytes(prefix ..< metaEnd), decoder: decoder),
                      parsed.rawLength <= cap - metaEnd
                else { return .malformed }
                meta = parsed.meta
                raw = metaEnd ..< metaEnd + parsed.rawLength
            }
            guard let meta, let raw else { return .malformed }
            guard received >= raw.upperBound else { return .waiting }
            guard received == raw.upperBound else { return .malformed }
            return .complete(meta, raw: bytes(raw))
        }

        private func decodeMeta(_ data: Data, decoder: WireDecoder) -> (meta: Meta, rawLength: Int)? {
            let cap = TerminalAttachFrameDecoder.maxBulkBytes
            switch kind {
            case .replay:
                guard let state = try? decoder.decode(TerminalVTStateWire.self, from: data),
                      let dataLength = state.dataLen, (0 ... cap).contains(dataLength),
                      (0 ... cap).contains(state.pendingLen ?? 0)
                else { return nil }
                return (.replay(state), dataLength + (state.pendingLen ?? 0))
            default:
                guard let snapshot = try? decoder.decode(TerminalSnapshotWire.self, from: data),
                      let dataLength = snapshot.dataLen, (0 ... cap).contains(dataLength)
                else { return nil }
                return (.snapshot(snapshot), dataLength)
            }
        }

        /// Bytes `range` of the event's payload: a slice of the read buffer when one chunk holds them all
        /// (no copy), else one copy that joins the chunks.
        private func bytes(_ range: Range<Int>) -> Data {
            var start = 0
            for chunk in chunks {
                let end = start + chunk.count
                if range.lowerBound >= start, range.upperBound <= end,
                   let slice = chunk.slice(from: range.lowerBound - start, length: range.count) {
                    return slice.data
                }
                start = end
            }
            var joined = Data(capacity: range.count)
            start = 0
            for chunk in chunks {
                let end = start + chunk.count
                let lower = max(range.lowerBound, start)
                let upper = min(range.upperBound, end)
                if lower < upper, let part = chunk.slice(from: lower - start, length: upper - lower) {
                    joined.append(part.data)
                }
                start = end
            }
            return joined
        }
    }
}
