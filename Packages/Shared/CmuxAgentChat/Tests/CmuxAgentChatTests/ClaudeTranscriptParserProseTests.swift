import Testing

@testable import CmuxAgentChat

extension ClaudeTranscriptParserTests {
    @Test("user text line maps to user prose with uuid id and line seq")
    func userProse() {
        let result = parser.parse(lines: [userLine(uuid: "u-9", content: "fix the bug")], startingSeq: 41)
        #expect(result.messages.count == 1)
        let message = result.messages[0]
        #expect(message.id == "u-9")
        #expect(message.seq == 41)
        #expect(message.role == .user)
        #expect(message.kind == .prose(ChatProse(text: "fix the bug")))
        #expect(result.updatedMessages.isEmpty)
    }

    @Test("user clipboard image path maps to attachment before remaining prose")
    func userClipboardAttachmentAndProse() {
        let path = "/tmp/x/clipboard-2026-07-08-101112-89abcdef.png"
        let result = parser.parse(
            lines: [userLine(uuid: "u-img", content: "\(path) check this")],
            startingSeq: 0
        )
        #expect(result.messages.count == 2)
        guard case .attachment(let attachment) = result.messages[0].kind else {
            Issue.record("expected attachment")
            return
        }
        #expect(attachment.media == .image)
        #expect(attachment.hostPath == path)
        #expect(attachment.displayName == "clipboard-2026-07-08-101112-89abcdef.png")
        #expect(result.messages[1].kind == .prose(ChatProse(text: "check this")))
    }

    @Test("two leading clipboard image paths emit attachments without empty prose")
    func userClipboardAttachmentsOnly() {
        let first = "/tmp/x/clipboard-2026-07-08-101112-89abcdef.png"
        let second = "/tmp/x/clipboard-2026-07-08-101113-01234567.JPG"
        let result = parser.parse(
            lines: [userLine(uuid: "u-imgs", content: "\(first) \(second)")],
            startingSeq: 0
        )
        #expect(result.messages.count == 2)
        let attachments = result.messages.compactMap { message -> ChatAttachment? in
            if case .attachment(let attachment) = message.kind { return attachment }
            return nil
        }
        #expect(attachments.map(\.hostPath) == [first, second])
    }

    @Test("non-matching leading path stays prose")
    func nonMatchingClipboardPathStaysProse() {
        let text = "/tmp/x/screenshot-2026-07-08.png check this"
        let result = parser.parse(lines: [userLine(uuid: "u-path", content: text)], startingSeq: 0)
        #expect(result.messages.count == 1)
        #expect(result.messages[0].kind == .prose(ChatProse(text: text)))
    }

    @Test("meta, command-tag, system-reminder, and non-message lines are skipped")
    func noiseSkipped() {
        let lines = [
            userLine(content: "<local-command-caveat>Caveat: ...</local-command-caveat>", isMeta: true),
            userLine(content: "<command-name>/model</command-name>\n<command-message>model</command-message>"),
            userLine(content: "<local-command-stdout>Set model</local-command-stdout>"),
            userLine(content: "<system-reminder>noise</system-reminder>"),
            #"{"type": "mode", "mode": "normal", "sessionId": "s-1"}"#,
            #"{"type": "summary", "summary": "Earlier conversation", "leafUuid": "x"}"#,
            #"{"type": "ai-title", "aiTitle": "Build a thing", "sessionId": "s-1"}"#,
            userLine(uuid: "u-real", content: "real prompt"),
        ]
        let result = parser.parse(lines: lines, startingSeq: 0)
        #expect(result.messages.count == 1)
        #expect(result.messages[0].id == "u-real")
        #expect(result.messages[0].seq == 7)
    }

    @Test("assistant text and thinking blocks map to prose and thought; empty thinking is skipped")
    func assistantTextAndThinking() {
        let lines = [
            assistantLine(uuid: "a-t", blocks: [["type": "thinking", "thinking": "", "signature": "CAIS"]]),
            assistantLine(uuid: "a-u", blocks: [["type": "thinking", "thinking": "weighing options", "signature": "CAIS"]]),
            assistantLine(uuid: "a-v", blocks: [["type": "text", "text": "Here is the plan."]]),
        ]
        let result = parser.parse(lines: lines, startingSeq: 0)
        #expect(result.messages.count == 2)
        #expect(result.messages[0].kind == .thought(ChatThought(text: "weighing options")))
        #expect(result.messages[1].role == .agent)
        #expect(result.messages[1].kind == .prose(ChatProse(text: "Here is the plan.")))
    }

    @Test("multiple blocks on one line share the seq and get suffixed ids")
    func multiBlockLine() {
        let line = assistantLine(
            uuid: "a-m",
            blocks: [
                ["type": "text", "text": "Running it now."],
                ["type": "tool_use", "id": "toolu_1", "name": "Bash", "input": ["command": "ls"]],
            ]
        )
        let result = parser.parse(lines: [line], startingSeq: 5)
        #expect(result.messages.count == 2)
        #expect(result.messages[0].id == "a-m")
        #expect(result.messages[1].id == "a-m#1")
        #expect(result.messages[0].seq == 5)
        #expect(result.messages[1].seq == 5)
    }
}
