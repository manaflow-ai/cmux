import Foundation
import Testing
@testable import CmuxNextRemoteView

struct RemoteAnnexBTests {
    @Test func splitsThreeAndFourByteStartCodes() {
        let bytes: [UInt8] = [0, 0, 0, 1, 0x67, 0xAA, 0, 0, 1, 0x68, 0xBB, 0, 0, 0, 0, 1, 0x65, 0xCC, 0xDD]
        let ranges = RemoteAnnexB.nalRanges(bytes)
        #expect(ranges.map { Array(bytes[$0]) } == [[0x67, 0xAA], [0x68, 0xBB], [0x65, 0xCC, 0xDD]])
    }

    @Test func lastUnitKeepsTrailingZeros() {
        let bytes: [UInt8] = [0, 0, 1, 0x41, 0x10, 0x00]
        #expect(RemoteAnnexB.nalRanges(bytes).map { Array(bytes[$0]) } == [[0x41, 0x10, 0x00]])
        #expect(RemoteAnnexB.nalRanges([0x12, 0x34]).isEmpty)
    }

    @Test func h264KeyframeYieldsParameterSetsAndLengthPrefixedSlices() {
        // AUD, SPS, PPS, IDR slice.
        let bytes: [UInt8] = [0, 0, 0, 1, 0x09, 0xF0, 0, 0, 0, 1, 0x67, 1, 2, 0, 0, 0, 1, 0x68, 3, 0, 0, 0, 1, 0x65, 9, 8, 7]
        let parsed = RemoteAnnexB.parse(bytes, codec: .h264)
        #expect(parsed.parameterSets == [[0x67, 1, 2], [0x68, 3]])
        #expect(parsed.isRandomAccess)
        #expect(parsed.sliceCount == 1)
        #expect(parsed.lengthPrefixed == [0, 0, 0, 4, 0x65, 9, 8, 7])
    }

    @Test func h264PredictedFrameHasNoParameterSets() {
        let parsed = RemoteAnnexB.parse([0, 0, 1, 0x41, 5, 6, 0, 0, 1, 0x06, 1], codec: .h264)
        #expect(parsed.parameterSets.isEmpty)
        #expect(!parsed.isRandomAccess)
        #expect(parsed.sliceCount == 1)
        // SEI (type 6) is kept for the decoder.
        #expect(parsed.lengthPrefixed == [0, 0, 0, 3, 0x41, 5, 6, 0, 0, 0, 2, 0x06, 1])
    }

    @Test func hevcNeedsVPSSPSAndPPS() {
        // NAL header byte 0 = type << 1: VPS 32, SPS 33, PPS 34, IDR_W_RADL 19, AUD 35.
        let nal: (UInt8) -> [UInt8] = { [0, 0, 0, 1, $0 << 1, 1] }
        let full = nal(35) + nal(32) + nal(33) + nal(34) + nal(19)
        let parsed = RemoteAnnexB.parse(full, codec: .hevc)
        #expect(parsed.parameterSets == [[64, 1], [66, 1], [68, 1]])
        #expect(parsed.isRandomAccess)
        #expect(parsed.sliceCount == 1)
        let missingVPS = RemoteAnnexB.parse(nal(33) + nal(34) + nal(1), codec: .hevc)
        #expect(missingVPS.parameterSets.isEmpty)
        #expect(!missingVPS.isRandomAccess)
        #expect(RemoteAnnexB.parse(nal(21), codec: .hevc).isRandomAccess) // CRA
    }
}
