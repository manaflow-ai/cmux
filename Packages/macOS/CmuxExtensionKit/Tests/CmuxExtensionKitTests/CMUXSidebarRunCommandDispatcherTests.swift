import Testing
@_spi(CmuxHostTransport) @testable import CmuxExtensionKit

@Suite
struct CMUXSidebarRunCommandDispatcherTests {
    private let dispatcher = CMUXSidebarRunCommandDispatcher()

    @Test
    func rejectsInvalidScalarsAndEmptyInputBeforeSending() {
        let invalidCommands = [
            "",
            "echo first\necho second",
            "printf\u{0}bad",
            "printf\tbad",
            "printf\u{7F}bad",
            "printf\u{80}bad",
            "printf\u{85}bad",
            "printf\u{9B}bad",
            "printf\u{9D}bad",
            "printf\u{9F}bad",
            "echo first\u{2028}echo second",
            "echo first\u{2029}echo second",
        ]

        for command in invalidCommands {
            var events: [String] = []
            let result = dispatcher.dispatch(
                command: command,
                targetKind: .terminal(.live),
                sendText: { text in events.append("text:\(text)"); return true },
                sendEnter: { events.append("enter"); return true }
            )

            #expect(result == .rejected(.commandRejected))
            #expect(events.isEmpty)
        }
    }

    @Test
    func rejectsCommandLargerThan8192UTF8Bytes() {
        let command = String(repeating: "é", count: 4_097)
        #expect(command.utf8.count > dispatcher.maximumCommandUTF8Bytes)

        var events: [String] = []
        let result = dispatcher.dispatch(
            command: command,
            targetKind: .terminal(.live),
            sendText: { _ in events.append("text"); return true },
            sendEnter: { events.append("enter"); return true }
        )

        #expect(result == .rejected(.commandRejected))
        #expect(events.isEmpty)
    }

    @Test
    func acceptsPrintableUnicodeAt8192UTF8ByteLimit() {
        let command = String(repeating: "é", count: 4_096)
        #expect(command.utf8.count == dispatcher.maximumCommandUTF8Bytes)

        var events: [String] = []
        let result = dispatcher.dispatch(
            command: command,
            targetKind: .terminal(.live),
            sendText: { text in events.append(text); return true },
            sendEnter: { events.append("enter"); return true }
        )

        #expect(result == .accepted)
        #expect(events == [command, "enter"])
    }

    @Test
    func rejectsMissingAndNonterminalTargets() {
        let cases: [(CMUXSidebarRunCommandTargetKind, CMUXSidebarRunCommandRejection)] = [
            (.missing, .terminalNotFound),
            (.nonterminal, .targetNotTerminal),
        ]

        for (targetKind, expectedRejection) in cases {
            var events: [String] = []
            let result = dispatcher.dispatch(
                command: "printf hello",
                targetKind: targetKind,
                sendText: { _ in events.append("text"); return true },
                sendEnter: { events.append("enter"); return true }
            )

            #expect(result == .rejected(expectedRejection))
            #expect(events.isEmpty)
        }
    }

    @Test
    func rejectsUnavailableTerminalsBeforeSendingInput() {
        for state in [
            CMUXSidebarRunCommandTerminalState.hibernated,
            .cold,
            .dead,
        ] {
            var events: [String] = []
            let result = dispatcher.dispatch(
                command: "printf hello",
                targetKind: .terminal(state),
                sendText: { _ in events.append("text"); return true },
                sendEnter: { events.append("enter"); return true }
            )

            #expect(result == .rejected(.terminalUnavailable))
            #expect(events.isEmpty)
        }
    }

    @Test
    func liveTargetSendsTextThenEnter() {
        var events: [String] = []
        let result = dispatcher.dispatch(
            command: "printf λ你好",
            targetKind: .terminal(.live),
            sendText: { text in events.append("text:\(text)"); return true },
            sendEnter: { events.append("enter"); return true }
        )

        #expect(result == .accepted)
        #expect(events == ["text:printf λ你好", "enter"])
    }

    @Test
    func rejectsTerminalInputFailuresInCallOrder() {
        var events: [String] = []
        let textRejected = dispatcher.dispatch(
            command: "printf hello",
            targetKind: .terminal(.live),
            sendText: { _ in events.append("text"); return false },
            sendEnter: { events.append("enter"); return true }
        )

        #expect(textRejected == .rejected(.terminalInputRejected))
        #expect(events == ["text"])

        events.removeAll()
        let enterRejected = dispatcher.dispatch(
            command: "printf hello",
            targetKind: .terminal(.live),
            sendText: { _ in events.append("text"); return true },
            sendEnter: { events.append("enter"); return false }
        )

        #expect(enterRejected == .rejected(.terminalInputRejected))
        #expect(events == ["text", "enter"])
    }
}
