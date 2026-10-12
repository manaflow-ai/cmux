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
    struct Segment: Equatable {
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
        var start = data.startIndex
        var index = data.startIndex
        while index < data.endIndex {
            if inPayload {
                let take = min(remaining, data.endIndex - index)
                index += take
                remaining -= take
            } else {
                header.append(data[index])
                index += 1
                guard header.count == Self.headerLength else { continue }
                type = header[0]
                remaining = Int(UInt32(header[1]) | UInt32(header[2]) << 8 | UInt32(header[3]) << 16 | UInt32(header[4]) << 24)
                header.removeAll(keepingCapacity: true)
                inPayload = true
            }
            if inPayload, remaining == 0 {
                inPayload = false
                if type == Self.controlType {
                    segments.append(Segment(bytes: data[start..<index], endsControlFrame: true))
                    start = index
                }
            }
        }
        if start < data.endIndex {
            segments.append(Segment(bytes: data[start..<data.endIndex], endsControlFrame: false))
        }
        return segments
    }
}
