import CmuxCollaboration
import Foundation
import Testing

@Suite
struct TerminalMouseReportFilterTests {
    private let filter = TerminalMouseReportFilter()

    @Test
    func removesSGRMouseMotionReport() {
        let input = Data("a\u{1B}[<35;12;4Mb".utf8)

        let filtered = filter.filtering(input)

        #expect(String(decoding: filtered, as: UTF8.self) == "ab")
    }

    @Test
    func removesSGRMouseReleaseReport() {
        let input = Data("a\u{1B}[<0;12;4mb".utf8)

        let filtered = filter.filtering(input)

        #expect(String(decoding: filtered, as: UTF8.self) == "ab")
    }

    @Test
    func removesLegacyX10MouseReport() {
        let input = Data([0x61, 0x1B, 0x5B, 0x4D, 0x43, 0x21, 0x22, 0x62])

        let filtered = filter.filtering(input)

        #expect(String(decoding: filtered, as: UTF8.self) == "ab")
    }

    @Test
    func keepsOrdinaryKeyboardInputAndIncompleteEscapes() {
        let input = Data("echo ok\r\u{1B}[<35;12".utf8)

        let filtered = filter.filtering(input)

        #expect(filtered == input)
    }
}
