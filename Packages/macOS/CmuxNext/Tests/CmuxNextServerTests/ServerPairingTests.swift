@testable import CmuxNextServer
import CoreImage
import Foundation
import Testing

struct ServerPairingTests {
    @Test func codeDisplaysWithADashAfterFourSymbols() {
        #expect(PairingCode.display("7KQ4M2XD") == "7KQ4-M2XD")
        #expect(PairingCode.display("7KQ4") == "7KQ4", "other lengths stay as they are")
    }

    @Test func typedCodesNormalizeCaseAndLookalikes() {
        #expect(PairingCode.normalize(" 7kq4-m2xd ") == "7KQ4M2XD")
        #expect(PairingCode.normalize("oIlL-0000") == "01110000")
        #expect(PairingCode.isComplete("7kq4 m2xd"))
        #expect(!PairingCode.isComplete("7KQ4-M2X"))
        #expect(!PairingCode.isComplete("7KQ4-M2XU"), "U is not a Crockford symbol")
    }

    @Test func editingShowsAtMostEightSymbolsWithADash() {
        #expect(PairingCode.editing("7kq") == "7KQ")
        #expect(PairingCode.editing("7kq4m") == "7KQ4-M")
        #expect(PairingCode.editing("7kq4m2xd99") == "7KQ4-M2XD")
        #expect(PairingCode.editing("7k!q4") == "7KQ4")
    }

    @Test func qrPayloadCarriesCodeAndFingerprint() {
        let offer = MockServerScenario.offer(now: MockServerScenario.referenceDate)
        #expect(offer.qrPayload == "https://cmux.com/pair?c=7KQ4M2XD#fp=Q4M2XD7KHJ9P3RTV")
        #expect(offer.displayCode == "7KQ4-M2XD")
        #expect(offer.words.count == 4)
        #expect(offer.expiresAt == MockServerScenario.referenceDate.addingTimeInterval(600))
    }

    @Test @MainActor func renderedQRDecodesToThePayload() throws {
        let payload = PairingCode.payload(code: "7KQ4M2XD", fingerprint: "Q4M2XD7KHJ9P3RTV")
        let image = try #require(QRCode.image(for: payload, quiet: 4))
        let scaled = CIImage(cgImage: image).transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let detector = try #require(CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        let messages = detector.features(in: scaled).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
        #expect(messages == [payload])
    }
}
