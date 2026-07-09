import Foundation
import Testing
import CmuxTerminal

@Suite("TerminalTextSnapshot payload assembly")
struct TerminalTextSnapshotTests {
    @Test("tail preserves split-suffix semantics without a full split")
    func tailPreservesSplitSuffixSemantics() {
        #expect("a\nb\nc".terminalTextTail(maxLines: 2) == "b\nc")
        #expect("a\nb\n".terminalTextTail(maxLines: 2) == "b\n")
        #expect("a".terminalTextTail(maxLines: 2) == "a")
        #expect("a\nb".terminalTextTail(maxLines: 0) == "")
    }

    @Test("scrollback payload tails before encoding and merges history+active")
    func payloadTailsScrollbackBeforeEncoding() throws {
        let result = TerminalTextPayload.make(
            from: TerminalTextRawSnapshot(
                viewport: nil,
                screen: "old\nscreen",
                history: "one\ntwo\nthree",
                active: "four\nfive"
            ),
            includeScrollback: true,
            lineLimit: 3
        )
        let payload = try result.get()

        #expect(payload.text == "three\nfour\nfive")
        #expect(payload.base64 == Data("three\nfour\nfive".utf8).base64EncodedString())
    }

    @Test("viewport payload returns the tailed viewport when scrollback is off")
    func viewportPayloadTailsViewport() throws {
        let result = TerminalTextPayload.make(
            from: TerminalTextRawSnapshot(viewport: "a\nb\nc\nd"),
            includeScrollback: false,
            lineLimit: 2
        )
        let payload = try result.get()
        #expect(payload.text == "c\nd")
    }

    @Test("missing viewport fails with the legacy message")
    func missingViewportFails() {
        let result = TerminalTextPayload.make(
            from: TerminalTextRawSnapshot(),
            includeScrollback: false,
            lineLimit: nil
        )
        #expect(result == .failure(TerminalTextPayloadError(message: "Failed to read terminal text")))
    }
}
