import Foundation

/// One H.264 NAL unit (no start code) and what it is.
struct H264Unit {
    enum Kind: Equatable {
        case sps, pps, keyframe, frame, other
    }

    let data: Data

    init(_ data: Data) { self.data = data }

    var kind: Kind {
        guard let first = data.first else { return .other }
        switch first & 0x1F {
        case 7: return .sps
        case 8: return .pps
        case 5: return .keyframe
        case 1: return .frame
        default: return .other
        }
    }
}
