import Testing

@testable import CmuxMobileCamera

@Suite struct QRCodeFrameSelectionTests {
    private let accepted = "cmux-ios://attach?v=3&tr=ticket-ref-123&r=100.64.0.5:52341"
    private let acceptsPairing: @Sendable (String) -> Bool = { $0.hasPrefix("cmux-ios://") }

    /// The pairing QR must be found even when another detection is ordered
    /// before it in the frame (the regression: scanning stopped at the
    /// frame's first object).
    @Test func picksQRCodeOrderedAfterOtherDetections() {
        let candidates = [
            QRCodeFrameCandidate(isQRCode: false, stringValue: "0123456789"),
            QRCodeFrameCandidate(isQRCode: true, stringValue: accepted),
        ]
        let code = QRCodeFrameSelection().firstAcceptedCode(in: candidates, accepts: acceptsPairing)
        #expect(code == accepted)
    }

    /// A rejected QR (someone else's code in the same frame) must not stop
    /// the scan from reading the pairing code next to it.
    @Test func skipsRejectedCodesAndTakesLaterAcceptedOne() {
        let candidates = [
            QRCodeFrameCandidate(isQRCode: true, stringValue: "https://example.com/menu"),
            QRCodeFrameCandidate(isQRCode: true, stringValue: nil),
            QRCodeFrameCandidate(isQRCode: true, stringValue: accepted),
        ]
        let code = QRCodeFrameSelection().firstAcceptedCode(in: candidates, accepts: acceptsPairing)
        #expect(code == accepted)
    }

    @Test func returnsNilWhenNoCandidateIsAccepted() {
        let candidates = [
            QRCodeFrameCandidate(isQRCode: true, stringValue: "https://example.com"),
            QRCodeFrameCandidate(isQRCode: false, stringValue: accepted),
        ]
        let code = QRCodeFrameSelection().firstAcceptedCode(in: candidates, accepts: acceptsPairing)
        #expect(code == nil)
    }

    @Test func returnsNilForEmptyFrame() {
        let code = QRCodeFrameSelection().firstAcceptedCode(in: [], accepts: acceptsPairing)
        #expect(code == nil)
    }

    /// The first accepted code wins when several qualify; later ones in the
    /// same frame are ignored.
    @Test func firstAcceptedCodeWinsAmongMultiple() {
        let other = "cmux-ios://attach?v=3&tr=other-ticket-ref&r=100.64.0.9:1024"
        let candidates = [
            QRCodeFrameCandidate(isQRCode: true, stringValue: accepted),
            QRCodeFrameCandidate(isQRCode: true, stringValue: other),
        ]
        let code = QRCodeFrameSelection().firstAcceptedCode(in: candidates, accepts: acceptsPairing)
        #expect(code == accepted)
    }
}
