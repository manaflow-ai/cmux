import Testing

@testable import CmuxAgentChatUI

struct ChatANSISanitizerTests {
    private let sanitizer = ChatANSISanitizer()

    @Test func plainTextPassesThrough() {
        #expect(sanitizer.sanitized("hello world\nsecond line") == "hello world\nsecond line")
    }

    @Test func csiColorCodesAreStripped() {
        #expect(sanitizer.sanitized("\u{1B}[31mred\u{1B}[0m plain") == "red plain")
        #expect(sanitizer.sanitized("\u{1B}[1;32;40mbold green\u{1B}[m") == "bold green")
    }

    @Test func csiCursorMovesAreStripped() {
        #expect(sanitizer.sanitized("a\u{1B}[2Kb\u{1B}[1Ac") == "abc")
    }

    @Test func oscSequencesAreStripped() {
        #expect(sanitizer.sanitized("\u{1B}]0;window title\u{07}hello") == "hello")
        #expect(sanitizer.sanitized("\u{1B}]8;;https://example.com\u{1B}\\link") == "link")
    }

    @Test func bareTwoCharacterEscapesAreStripped() {
        #expect(sanitizer.sanitized("\u{1B}=text\u{1B}>more") == "textmore")
    }

    @Test func carriageReturnProgressCollapsesToFinalSegment() {
        let progress = "Downloading 10%\rDownloading 55%\rDownloading 100%\ndone"
        #expect(sanitizer.sanitized(progress) == "Downloading 100%\ndone")
    }

    @Test func carriageReturnCollapsePreservesOtherLines() {
        let text = "first\nsetup\rreplaced\nlast"
        #expect(sanitizer.sanitized(text) == "first\nreplaced\nlast")
    }

    @Test func combinedEscapesAndProgress() {
        let text = "\u{1B}[32mok\u{1B}[0m 1%\r\u{1B}[32mok\u{1B}[0m 100%\nfinished"
        #expect(sanitizer.sanitized(text) == "ok 100%\nfinished")
    }

    @Test func trailingEscapeAtEndOfInputDoesNotCrash() {
        #expect(sanitizer.sanitized("text\u{1B}") == "text")
        #expect(sanitizer.sanitized("text\u{1B}[31") == "text")
    }
}
