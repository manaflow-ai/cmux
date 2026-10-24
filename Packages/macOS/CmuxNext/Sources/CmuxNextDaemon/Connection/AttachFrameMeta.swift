import Foundation

/// The JSON meta and the raw data of a SNAPSHOT, SNAPSHOT_MORE or REPLAY
/// payload (`meta_len u32 | meta | data`).
struct AttachFrameMeta {
    var meta: Data
    var data: Data

    init?(_ payload: Data) {
        guard let raw = AttachFrameHeader.littleEndian(Array(payload.prefix(4)), from: 0, count: 4),
              let length = Int(exactly: raw), length <= payload.count - 4 else { return nil }
        let rest = payload.dropFirst(4)
        meta = rest.prefix(length)
        data = rest.dropFirst(length)
    }
}
