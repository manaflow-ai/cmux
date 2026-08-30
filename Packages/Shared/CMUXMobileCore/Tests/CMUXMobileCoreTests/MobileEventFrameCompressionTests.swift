import Foundation
import Testing
@testable import CMUXMobileCore

@Suite struct MobileEventFrameCompressionTests {
    private var sampleEnvelope: Data {
        // Repetitive JSON, like a render-grid delta: compresses well and is
        // comfortably above the minimum compressible size.
        let rows = (0..<40).map { #"{"r":\#($0),"t":"the same row text again and again"}"# }
        return Data(#"{"kind":"event","topic":"terminal.render_grid","payload":{"rows":[\#(rows.joined(separator: ","))]}}"#.utf8)
    }

    @Test func roundTripsAndShrinks() throws {
        let envelope = sampleEnvelope
        let compressed = try #require(MobileEventFrameCompression.compressedPayload(for: envelope))
        #expect(compressed.first == MobileEventFrameCompression.compressedFrameMagic)
        #expect(compressed.count < envelope.count)
        let inflated = MobileEventFrameCompression.inflatedFrame(
            compressed,
            maximumInflatedByteCount: envelope.count
        )
        #expect(inflated == envelope)
    }

    @Test func plainFramesPassThroughUnchanged() {
        let plain = Data(#"{"kind":"event"}"#.utf8)
        #expect(MobileEventFrameCompression.inflatedFrame(plain, maximumInflatedByteCount: 1024) == plain)
    }

    @Test func smallEnvelopesAreNotCompressed() {
        #expect(MobileEventFrameCompression.compressedPayload(for: Data(#"{"a":1}"#.utf8)) == nil)
    }

    @Test func inflationRespectsTheOutputCap() throws {
        let envelope = sampleEnvelope
        let compressed = try #require(MobileEventFrameCompression.compressedPayload(for: envelope))
        // A cap below the true size must reject the frame (zip-bomb guard).
        #expect(MobileEventFrameCompression.inflatedFrame(
            compressed,
            maximumInflatedByteCount: envelope.count - 1
        ) == nil)
    }

    @Test func corruptCompressedFramesAreRejected() {
        var corrupt = Data([MobileEventFrameCompression.compressedFrameMagic])
        corrupt.append(Data([0xde, 0xad, 0xbe, 0xef]))
        #expect(MobileEventFrameCompression.inflatedFrame(corrupt, maximumInflatedByteCount: 1024) == nil)
    }
}
