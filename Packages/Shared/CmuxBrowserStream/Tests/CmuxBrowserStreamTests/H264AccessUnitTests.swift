import CmuxBrowserStream
import Foundation
import Testing

@Suite("H.264 Annex-B and length-prefixed access units")
struct H264AccessUnitTests {
    static let sps = Data([0x67, 0x42, 0x00, 0x1f])
    static let pps = Data([0x68, 0xce, 0x3c, 0x80])
    static let idr = Data([0x65, 0x88, 0x84, 0x00])

    @Test func parsesThreeAndFourByteStartCodes() {
        let bytes = Data([0, 0, 0, 1]) + Self.sps + Data([0, 0, 1]) + Self.pps + Data([0, 0, 0, 1]) + Self.idr
        let unit = H264AccessUnit(annexB: bytes)
        #expect(unit.nalUnits == [Self.sps, Self.pps, Self.idr])
        #expect(unit.isKeyframe)
        #expect(unit.sps == Self.sps)
        #expect(unit.pps == Self.pps)
    }

    @Test func lengthPrefixedRoundTripsThroughAnnexB() throws {
        let avcc = Data([0, 0, 0, 4]) + Self.idr
        let unit = try H264AccessUnit(lengthPrefixed: avcc, parameterSets: [Self.sps, Self.pps])
        let parsed = H264AccessUnit(annexB: unit.annexB)
        #expect(parsed.nalUnits == [Self.sps, Self.pps, Self.idr])
        #expect(parsed.lengthPrefixedSlices == avcc)
    }

    @Test func truncatedLengthsThrow() {
        #expect(throws: RdWireError.self) { try H264AccessUnit(lengthPrefixed: Data([0, 0, 0, 9, 1])) }
    }
}
