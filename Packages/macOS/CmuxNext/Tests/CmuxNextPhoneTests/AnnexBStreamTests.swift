import Foundation
import Testing
@testable import CmuxNextPhone

/// The H.264 byte stream `adb exec-out screenrecord --output-format=h264 -`
/// writes arrives in arbitrary pipe chunks; the parser must cut it into whole
/// NAL units no matter where the chunks split.
@Suite struct AnnexBStreamTests {
    // SPS (type 7), PPS (type 8), IDR slice (type 5), non-IDR slice (type 1).
    let sps: [UInt8] = [0x67, 0x42, 0xC0, 0x1E, 0xDA, 0x02, 0x80]
    let pps: [UInt8] = [0x68, 0xCE, 0x3C, 0x80]
    let idr: [UInt8] = [0x65, 0x88, 0x84, 0x00, 0x00, 0x03, 0x00, 0x21]
    let slice: [UInt8] = [0x41, 0x9A, 0x02, 0x80] // a unit never ends in 0x00 (rbsp trailing bits)

    var stream: [UInt8] {
        [0, 0, 0, 1] + sps + [0, 0, 0, 1] + pps + [0, 0, 1] + idr + [0, 0, 0, 1] + slice + [0, 0, 0, 1]
    }

    @Test(arguments: [1, 2, 3, 5, 7, 64])
    func unitsComeOutWholeForAnyChunkSize(chunk: Int) {
        var parser = AnnexBParser()
        var units: [[UInt8]] = []
        var index = 0
        while index < stream.count {
            let end = min(stream.count, index + chunk)
            units += parser.append(Data(stream[index..<end])).map { Array($0) }
            index = end
        }
        #expect(units == [sps, pps, idr, slice])
    }

    @Test func theLastUnitWaitsForTheNextStartCode() {
        var parser = AnnexBParser()
        let units = parser.append(Data([0, 0, 0, 1] + sps + [0, 0, 0, 1] + pps))
        #expect(units.map { Array($0) } == [sps])
        #expect(parser.flush().map { Array($0) } == pps)
    }

    @Test func unitTypesAreRead() {
        #expect(H264Unit(Data(sps)).kind == .sps)
        #expect(H264Unit(Data(pps)).kind == .pps)
        #expect(H264Unit(Data(idr)).kind == .keyframe)
        #expect(H264Unit(Data(slice)).kind == .frame)
        #expect(H264Unit(Data([0x06, 0x05])).kind == .other)
    }
}
