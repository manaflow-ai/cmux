import Foundation
import Testing
@testable import CmuxNextDaemon

struct H1CaptureOldEncoderTests {
    @Test func printOldBytes() throws {
        func line<R: DaemonRequest>(_ r: R) throws -> String { String(decoding: try WireCoding.encodeRequest(r, id: 7), as: UTF8.self) }
        print("H1CAP1 " + (try line(TerminalFindRequest(surface: 12, query: "needle"))))
        print("H1CAP2 " + (try line(TerminalFindRequest(surface: 12, query: "n.+e", caseSensitive: true, wholeWord: true, regex: true, before: 40, epoch: 3))))
        print("H1CAP3 " + (try line(OfferLinkToPhoneRequest(terminalID: "terminal_a", url: "https://example.com/x"))))
    }
}
