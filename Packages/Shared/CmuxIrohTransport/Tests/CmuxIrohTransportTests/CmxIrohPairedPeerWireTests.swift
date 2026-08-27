import Foundation
import Testing
@testable import CmuxIrohTransport

/// Wire-level contract for allowlist admission: an already-paired phone opens
/// its control stream with NO admission credential, and the header remains
/// representable and round-trippable in that credential-less form.
@Suite
struct CmxIrohPairedPeerWireTests {
    @Test
    func controlHeaderWithoutCredentialIsValid() throws {
        let header = try CmxIrohStreamHeader(lane: .control, credential: nil)
        #expect(header.credential == nil)
        #expect(header.lane == .control)
    }

    @Test
    func codecRoundTripsCredentiallessControlHeader() throws {
        let codec = try CmxIrohStreamHeaderCodec()
        let encoded = try codec.encode(
            try CmxIrohStreamHeader(lane: .control, credential: nil)
        )
        let decoded = try codec.decodePrefix(encoded)
        #expect(decoded.header.lane == .control)
        #expect(decoded.header.credential == nil)
        #expect(decoded.consumedByteCount == encoded.count)
    }

    @Test
    func codecDecodesCredentialCodeZeroControlFrame() throws {
        let codec = try CmxIrohStreamHeaderCodec()
        var frame = Data("CMUXIRH1".utf8)
        frame.append(1) // version
        frame.append(1) // lane: control
        frame.append(0) // flags
        frame.append(0) // credential code: none (allowlist admission)
        frame.append(contentsOf: [0, 0, 0, 0] as [UInt8]) // payload byte count
        let decoded = try codec.decodePrefix(frame)
        #expect(decoded.header.lane == .control)
        #expect(decoded.header.credential == nil)
    }
}
