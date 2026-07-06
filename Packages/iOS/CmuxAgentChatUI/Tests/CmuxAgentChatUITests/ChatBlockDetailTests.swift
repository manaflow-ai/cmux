import CmuxAgentChat
import Foundation
import Testing

@testable import CmuxAgentChatUI

struct ChatBlockDetailTests {
    @Test func toolDetailPreservesInputAndOutput() {
        let message = ChatMessage(
            id: "tool-1",
            seq: 1,
            role: .agent,
            timestamp: Date(timeIntervalSince1970: 0),
            kind: .toolUse(ChatToolUse(
                toolName: "WebFetch",
                summary: "WebFetch ci.example.com/runs/8412",
                inputDetail: "url: https://ci.example.com/runs/8412",
                output: "build failed at step 4",
                status: .failed
            ))
        )

        let detail = ChatBlockDetail.make(message: message)

        #expect(detail?.id == "msg-tool-1")
        #expect(detail?.sections.map(\.id) == ["input", "output"])
        #expect(detail?.sections[0].text == "url: https://ci.example.com/runs/8412")
        #expect(detail?.sections[1].text == "build failed at step 4")
        #expect(detail?.copyText == "url: https://ci.example.com/runs/8412\n\nbuild failed at step 4")
    }

    @Test func codeBlockDetailKeepsTheFullCodeText() {
        let code = (1...12)
            .map { "line \($0)" }
            .joined(separator: "\n")

        let detail = ChatBlockDetail.codeBlock(id: "code-1", code: code, language: "swift")

        #expect(detail.id == "code-1")
        #expect(detail.subtitle == "swift")
        #expect(detail.sections.map(\.id) == ["code"])
        #expect(detail.sections[0].text == code)
        #expect(detail.copyText == code)
    }

    @Test func terminalDetailSanitizesControlSequences() {
        let block = TerminalCommandBlock(
            id: 42,
            command: "npm test",
            output: "\u{1B}[31mfail\u{1B}[0m\rpass",
            exitCode: 0,
            isRunning: false
        )

        let detail = ChatBlockDetail.make(block: block)

        #expect(detail.id == "term-42")
        #expect(detail.sections.map(\.id) == ["command", "output"])
        #expect(detail.sections[0].text == "npm test")
        #expect(detail.sections[1].text == "pass")
        #expect(detail.copyText == "npm test\n\npass")
    }
}
