import Foundation

/// The QP of an H.264 frame, read from its first slice header, as libwebrtc's
/// `H264BitstreamParser` reads it for its own VideoToolbox encoder. VideoToolbox does
/// not report a frame's QP, and libwebrtc's quality scaler needs one: without it, a
/// stream that must keep its frame rate (Smooth) is never scaled down and drops frames
/// instead. The parameter sets are kept from the keyframe that carried them.
///
/// Returns nil for what it does not read (several slice groups, weighted prediction),
/// so the frame reports no QP, as before.
struct H264SliceQP {
    struct SPS: Equatable {
        var separateColourPlane = false
        var log2MaxFrameNum = 4
        var picOrderCntType = 0
        var log2MaxPicOrderCntLsb = 4
        var deltaPicOrderAlwaysZero = false
        var frameMbsOnly = true
    }

    struct PPS: Equatable {
        var cabac = false
        var bottomFieldPicOrderInFramePresent = false
        var weightedPred = false
        var weightedBipredIdc = 0
        var picInitQPMinus26 = 0
        var redundantPicCntPresent = false
    }

    private(set) var sps: SPS?
    private(set) var pps: PPS?

    /// The first slice's QP in an Annex B access unit; SPS and PPS before it are kept.
    mutating func qp(annexB bytes: [UInt8]) -> Int? {
        for (start, end) in Self.nalUnits(bytes) where end > start {
            let header = bytes[start]
            switch header & 0x1F {
            case 7: sps = Self.parseSPS(Self.rbsp(bytes, start + 1, end))
            case 8: pps = Self.parsePPS(Self.rbsp(bytes, start + 1, end))
            case 1, 5:
                guard let sps, let pps else { return nil }
                return Self.sliceQP(Self.rbsp(bytes, start + 1, end), sps: sps, pps: pps,
                                    idr: header & 0x1F == 5, referenced: header >> 5 & 3 != 0)
            default: continue
            }
        }
        return nil
    }

    /// Each NAL unit's payload range (its header byte first) after a 3- or 4-byte start code.
    static func nalUnits(_ bytes: [UInt8]) -> [(Int, Int)] {
        var starts: [Int] = []
        var index = 0
        while index + 2 < bytes.count {
            if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 {
                starts.append(index + 3)
                index += 3
            } else {
                index += 1
            }
        }
        return starts.enumerated().map { offset, start in
            var end = offset + 1 < starts.count ? starts[offset + 1] - 3 : bytes.count
            if end > start, offset + 1 < starts.count, bytes[end - 1] == 0 { end -= 1 } // a 4-byte start code's leading zero
            return (start, end)
        }
    }

    /// The payload without its emulation prevention bytes (00 00 03 → 00 00).
    static func rbsp(_ bytes: [UInt8], _ start: Int, _ end: Int) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(max(end - start, 0))
        var zeros = 0
        var index = start
        while index < end {
            let byte = bytes[index]
            if zeros >= 2, byte == 3 {
                zeros = 0
                index += 1
                continue
            }
            zeros = byte == 0 ? zeros + 1 : 0
            out.append(byte)
            index += 1
        }
        return out
    }

    static func parseSPS(_ rbsp: [UInt8]) -> SPS? {
        var bits = Bits(rbsp)
        var sps = SPS()
        guard let profile = bits.read(8), bits.read(16) != nil, bits.ue() != nil else { return nil }
        if [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135].contains(profile) {
            guard let chroma = bits.ue() else { return nil }
            if chroma == 3 { guard let flag = bits.flag() else { return nil }; sps.separateColourPlane = flag }
            guard bits.ue() != nil, bits.ue() != nil, bits.flag() != nil, let matrices = bits.flag() else { return nil }
            if matrices {
                for list in 0 ..< (chroma == 3 ? 12 : 8) {
                    guard let present = bits.flag() else { return nil }
                    if present, !bits.skipScalingList(list < 6 ? 16 : 64) { return nil }
                }
            }
        }
        guard let frameNum = bits.ue(), let pocType = bits.ue() else { return nil }
        sps.log2MaxFrameNum = frameNum + 4
        sps.picOrderCntType = pocType
        if pocType == 0 {
            guard let lsb = bits.ue() else { return nil }
            sps.log2MaxPicOrderCntLsb = lsb + 4
        } else if pocType == 1 {
            guard let zero = bits.flag(), bits.se() != nil, bits.se() != nil, let cycle = bits.ue() else { return nil }
            sps.deltaPicOrderAlwaysZero = zero
            for _ in 0 ..< cycle { guard bits.se() != nil else { return nil } }
        }
        guard bits.ue() != nil, bits.flag() != nil, bits.ue() != nil, bits.ue() != nil, let frameMbsOnly = bits.flag() else { return nil }
        sps.frameMbsOnly = frameMbsOnly
        return sps
    }

    static func parsePPS(_ rbsp: [UInt8]) -> PPS? {
        var bits = Bits(rbsp)
        var pps = PPS()
        guard bits.ue() != nil, bits.ue() != nil, let cabac = bits.flag(), let bottom = bits.flag(),
              let groups = bits.ue(), groups == 0, bits.ue() != nil, bits.ue() != nil,
              let weighted = bits.flag(), let bipred = bits.read(2), let qp = bits.se(),
              bits.se() != nil, bits.se() != nil, bits.flag() != nil, bits.flag() != nil, let redundant = bits.flag()
        else { return nil }
        pps.cabac = cabac
        pps.bottomFieldPicOrderInFramePresent = bottom
        pps.weightedPred = weighted
        pps.weightedBipredIdc = bipred
        pps.picInitQPMinus26 = qp
        pps.redundantPicCntPresent = redundant
        return pps
    }

    static func sliceQP(_ rbsp: [UInt8], sps: SPS, pps: PPS, idr: Bool, referenced: Bool) -> Int? {
        var bits = Bits(rbsp)
        guard bits.ue() != nil, let rawType = bits.ue(), bits.ue() != nil else { return nil }
        let type = rawType % 5 // 0 P, 1 B, 2 I, 3 SP, 4 SI
        if sps.separateColourPlane { guard bits.read(2) != nil else { return nil } }
        guard bits.read(sps.log2MaxFrameNum) != nil else { return nil }
        var field = false
        if !sps.frameMbsOnly {
            guard let flag = bits.flag() else { return nil }
            field = flag
            if field { guard bits.flag() != nil else { return nil } }
        }
        if idr { guard bits.ue() != nil else { return nil } }
        if sps.picOrderCntType == 0 {
            guard bits.read(sps.log2MaxPicOrderCntLsb) != nil else { return nil }
            if pps.bottomFieldPicOrderInFramePresent, !field { guard bits.se() != nil else { return nil } }
        }
        if sps.picOrderCntType == 1, !sps.deltaPicOrderAlwaysZero {
            guard bits.se() != nil else { return nil }
            if pps.bottomFieldPicOrderInFramePresent, !field { guard bits.se() != nil else { return nil } }
        }
        if pps.redundantPicCntPresent { guard bits.ue() != nil else { return nil } }
        if type == 1 { guard bits.flag() != nil else { return nil } }
        if type == 0 || type == 1 || type == 3 {
            guard let override = bits.flag() else { return nil }
            if override {
                guard bits.ue() != nil else { return nil }
                if type == 1 { guard bits.ue() != nil else { return nil } }
            }
        }
        if type != 2, type != 4 {
            for _ in 0 ..< (type == 1 ? 2 : 1) {
                guard let modified = bits.flag() else { return nil }
                while modified {
                    guard let idc = bits.ue() else { return nil }
                    if idc == 3 { break }
                    guard bits.ue() != nil else { return nil }
                }
            }
        }
        if (pps.weightedPred && (type == 0 || type == 3)) || (pps.weightedBipredIdc == 1 && type == 1) { return nil }
        if referenced {
            if idr {
                guard bits.flag() != nil, bits.flag() != nil else { return nil }
            } else {
                guard let adaptive = bits.flag() else { return nil }
                while adaptive {
                    guard let operation = bits.ue() else { return nil }
                    if operation == 0 { break }
                    if [1, 3].contains(operation) { guard bits.ue() != nil else { return nil } }
                    if operation == 2 { guard bits.ue() != nil else { return nil } }
                    if [3, 6].contains(operation) { guard bits.ue() != nil else { return nil } }
                    if operation == 4 { guard bits.ue() != nil else { return nil } }
                }
            }
        }
        if pps.cabac, type != 2, type != 4 { guard bits.ue() != nil else { return nil } }
        guard let delta = bits.se() else { return nil }
        let qp = 26 + pps.picInitQPMinus26 + delta
        return (0 ... 51).contains(qp) ? qp : nil
    }

    /// An RBSP read bit by bit (big-endian), with Exp-Golomb codes.
    struct Bits {
        private let bytes: [UInt8]
        private var position = 0

        init(_ bytes: [UInt8]) { self.bytes = bytes }

        mutating func read(_ count: Int) -> Int? {
            guard count >= 0, count <= 32, position + count <= bytes.count * 8 else { return nil }
            var value = 0
            for _ in 0 ..< count {
                value = value << 1 | Int(bytes[position >> 3] >> (7 - UInt8(position & 7)) & 1)
                position += 1
            }
            return value
        }

        mutating func flag() -> Bool? { read(1).map { $0 == 1 } }

        mutating func ue() -> Int? {
            var zeros = 0
            while true {
                guard let bit = read(1) else { return nil }
                if bit == 1 { break }
                zeros += 1
                if zeros > 31 { return nil }
            }
            guard let rest = read(zeros) else { return nil }
            return (1 << zeros) - 1 + rest
        }

        mutating func se() -> Int? {
            guard let code = ue() else { return nil }
            return code & 1 == 1 ? (code + 1) / 2 : -(code / 2)
        }

        mutating func skipScalingList(_ size: Int) -> Bool {
            var last = 8, next = 8
            for _ in 0 ..< size {
                if next != 0 {
                    guard let delta = se() else { return false }
                    next = (last + delta + 256) % 256
                }
                last = next == 0 ? last : next
            }
            return true
        }
    }
}
