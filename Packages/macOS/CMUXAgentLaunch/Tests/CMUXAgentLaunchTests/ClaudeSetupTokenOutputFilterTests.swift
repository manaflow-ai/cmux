import Foundation
import Testing
@testable import CMUXAgentLaunch

@Suite("Claude setup-token output filter")
struct ClaudeSetupTokenOutputFilterTests {
    private static let token = "sk-ant-oat01-abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJ_-"

    /// Feeds `chunks` one call at a time and returns what each call printed.
    private func run(_ chunks: [String]) -> (printed: [String], rest: String, token: String?) {
        var filter = ClaudeSetupTokenOutputFilter()
        let printed = chunks.map { String(decoding: filter.consume(Data($0.utf8)), as: UTF8.self) }
        let rest = String(decoding: filter.finish(), as: UTF8.self)
        return (printed, rest, filter.token)
    }

    @Test func textBeforeTheTokenIsPrintedByTheCallThatReceivedIt() {
        let result = run(["Open https://example.test/authorize\r\nPaste code here if prompted > "])

        #expect(result.printed == ["Open https://example.test/authorize\r\nPaste code here if prompted > "])
        #expect(result.rest.isEmpty)
        #expect(result.token == nil)
    }

    @Test func tokenIsCapturedAndNeverPrinted() {
        let result = run(["Your token:\r\n\r\n\(Self.token)\r\n\r\nStore it somewhere safe.\r\n"])

        #expect(result.printed == ["Your token:\r\n\r\n[REDACTED]\r\n\r\nStore it somewhere safe.\r\n"])
        #expect(result.rest.isEmpty)
        #expect(result.token == Self.token)
    }

    // The pipe can hand over the output cut anywhere, including inside the
    // token and inside its prefix.
    @Test(arguments: 0...(ClaudeSetupTokenOutputFilterTests.token.utf8.count + 8))
    func tokenSplitAtAnyOffsetIsNeverPrinted(offset: Int) {
        let bytes = Array("link\r\n\(Self.token)\r\ndone\r\n".utf8)
        let result = run([
            String(decoding: bytes[..<offset], as: UTF8.self),
            String(decoding: bytes[offset...], as: UTF8.self),
        ])

        let printed = result.printed.joined() + result.rest
        #expect(printed == "link\r\n[REDACTED]\r\ndone\r\n")
        #expect(result.token == Self.token)
        for call in result.printed {
            #expect(!call.contains("abcdefghij"))
        }
    }

    @Test func tokenFedOneByteAtATimeIsNeverPrinted() {
        let text = "a s sk sk-ant \(Self.token) z"
        let result = run(text.map(String.init))

        #expect(result.printed.joined() + result.rest == "a s sk sk-ant [REDACTED] z")
        #expect(result.token == Self.token)
    }

    @Test func tokenAtTheEndOfTheOutputIsSettledByFinish() {
        let result = run(["token: \(Self.token)"])

        #expect(result.printed == ["token: "])
        #expect(result.rest == "[REDACTED]")
        #expect(result.token == Self.token)
    }

    // Help text quotes the prefix; it is not a secret and must still show.
    @Test func prefixWithoutATokenAfterItIsPrinted() {
        let result = run(["expected sk-ant-oat01-... or ", "sk-ant-oat01-short", "\n", "sk-ant-oa"])

        #expect(result.printed.joined() + result.rest == "expected sk-ant-oat01-... or sk-ant-oat01-short\nsk-ant-oa")
        #expect(result.token == nil)
    }

    @Test func restartedPrefixStillFindsTheToken() {
        let result = run(["sk-sk-ant-\(Self.token) "])

        #expect(result.printed == ["sk-sk-ant-[REDACTED] "])
        #expect(result.token == Self.token)
    }

    @Test func onlyTheFirstTokenIsKeptAndEveryTokenIsHidden() {
        let second = "sk-ant-oat01-" + String(repeating: "z", count: 40)
        let result = run(["\(Self.token)\n\(second)\n"])

        #expect(result.printed == ["[REDACTED]\n[REDACTED]\n"])
        #expect(result.token == Self.token)
    }

    // A run longer than any token is cut off at the same length as before,
    // and none of it is printed or kept in memory.
    @Test func overlongRunIsDroppedWithoutBeingPrinted() {
        let body = String(repeating: "q", count: 5_000)
        let result = run(["sk-ant-oat01-" + String(body.prefix(2_500)), String(body.dropFirst(2_500)) + " end"])

        #expect(result.printed.joined() + result.rest == "[REDACTED] end")
        #expect(result.token == "sk-ant-oat01-" + String(repeating: "q", count: 1_000))
    }

    @Test func bytesThatAreNotTextPassThroughUnchanged() {
        var filter = ClaudeSetupTokenOutputFilter()
        let bytes = Data([0x1B, 0x5B, 0x32, 0x4B, 0xFF, 0xC3, 0x00, 0x73])

        #expect(filter.consume(bytes) == Data(bytes.dropLast()))
        #expect(filter.finish() == Data([0x73]))
    }
}
