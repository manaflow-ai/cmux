import CoreGraphics
@testable import CmuxNextServer
import Foundation
import Testing

/// The pairing QR codes are kept for the ``QRCode/kept`` most recently drawn payloads:
/// a new payload past that evicts the least recently drawn one, a drawn one moves to the newest, and
/// an evicted payload is drawn again.
@MainActor @Suite(.serialized) struct QRCodeCacheTests {
    /// Payloads no other test draws.
    private static func payload(_ name: String) -> String {
        "cmux-pair:\(UUID().uuidString):\(name)"
    }

    @Test func theCacheKeepsTheMostRecentlyDrawnPayloadsAndDrawsAnEvictedOneAgain() throws {
        let names = ["a", "b", "c", "d"].map(Self.payload)
        var images: [String: CGImage] = [:]
        for name in names { images[name] = try #require(QRCode.image(for: name)) }
        #expect(QRCode.count == QRCode.kept)

        // A hit moves the oldest payload to the newest: the next new payload evicts the second oldest.
        #expect(QRCode.image(for: names[0]) === images[names[0]], "a kept payload was drawn again")
        let fifth = Self.payload("e")
        _ = try #require(QRCode.image(for: fifth))
        #expect(QRCode.count == QRCode.kept, "the cache grew past its bound")

        #expect(QRCode.image(for: names[0]) === images[names[0]], "the hit did not keep the oldest payload")
        let again = try #require(QRCode.image(for: names[1]), "an evicted payload must be drawn again")
        #expect(again !== images[names[1]], "the second oldest payload was not evicted")
        #expect(QRCode.count == QRCode.kept)
    }
}
