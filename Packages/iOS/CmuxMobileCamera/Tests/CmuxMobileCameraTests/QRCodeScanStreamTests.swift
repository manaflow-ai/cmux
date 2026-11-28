import Testing
@testable import CmuxMobileCamera

@Suite struct QRCodeScanStreamTests {
    @Test func yieldsCodesInOrderThenFinishes() async {
        let stream = QRCodeScanStream()
        stream.yield("cmux-ios://one")
        stream.yield("cmux-ios://two")
        stream.finish()

        var seen: [String] = []
        for await code in stream.codes {
            seen.append(code)
        }
        #expect(seen == ["cmux-ios://one", "cmux-ios://two"])
    }

    @Test func finishWithoutYieldProducesEmptySequence() async {
        let stream = QRCodeScanStream()
        stream.finish()

        var seen: [String] = []
        for await code in stream.codes {
            seen.append(code)
        }
        #expect(seen.isEmpty)
    }
}
