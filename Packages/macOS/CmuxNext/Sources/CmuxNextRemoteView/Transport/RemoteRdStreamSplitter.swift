import Foundation

/// Cuts received stream-carrier bytes (`u8 type, u32 len` little-endian,
/// payload) right after every control frame, so the transport can act on a
/// control message before it reads the bytes that follow it: rb/1
/// `rb.surface.show {stream}` opens its stream in the core before that
/// stream's first datagrams, which the host writes right behind it, are
/// pushed (a datagram of a stream that is not open is skipped). Only tracks
/// frame boundaries; the core validates the frames.
nonisolated struct RemoteRdStreamSplitter {
    /// One piece of the received bytes, in order.
    nonisolated struct Segment: Equatable {
        var bytes: Data
        /// The piece ends with the last byte of a control frame.
        var endsControlFrame: Bool
    }

    private var header: [UInt8] = []
    private var remaining = 0
    private var type: UInt8 = 0
    private var inPayload = false

    private static let controlType: UInt8 = 1
    private static let headerLength = 5

    mutating func split(_ data: Data) -> [Segment] {
        var segments: [Segment] = []
        // `rest` is the bytes not yet walked and `piece` the bytes since the last cut: both are
        // counted from the front, and a cut is a prefix or suffix of `data`: no byte is subscripted.
        var rest = data
        var piece = 0
        while !rest.isEmpty {
            if inPayload {
                let take = min(remaining, rest.count)
                rest = rest.dropFirst(take)
                piece += take
                remaining -= take
            } else if let byte = rest.popFirst() {
                piece += 1
                header.append(byte)
                guard header.count == Self.headerLength else { continue }
                type = header.first ?? 0
                // A u32 length always fits a 64-bit Int.
                remaining = Int(truncatingIfNeeded: header.dropFirst().reversed().reduce(UInt32(0)) { $0 << 8 | UInt32(truncatingIfNeeded: $1) })
                header.removeAll(keepingCapacity: true)
                inPayload = true
            }
            if inPayload, remaining == 0 {
                inPayload = false
                if type == Self.controlType {
                    segments.append(Segment(bytes: data.dropFirst(data.count - rest.count - piece).prefix(piece), endsControlFrame: true))
                    piece = 0
                }
            }
        }
        if piece > 0 {
            segments.append(Segment(bytes: data.suffix(piece), endsControlFrame: false))
        }
        return segments
    }
}
