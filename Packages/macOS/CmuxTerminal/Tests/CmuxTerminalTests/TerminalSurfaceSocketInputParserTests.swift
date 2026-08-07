import Foundation
import Testing
import CmuxTerminalCore
@testable import CmuxTerminal

@Suite struct TerminalSurfaceSocketInputParserTests {
    @Test func osc11AndCPRRepliesStayTerminalBytes() {
        let firstOSC11 = "\u{1B}]11;rgb:1e1e/1e1e/1e1e\u{1B}\\"
        let firstCPR = "\u{1B}[50;1R"
        let secondOSC11 = "\u{1B}]11;rgb:1e1e/1e1e/1e1e\u{1B}\\"
        let secondCPR = "\u{1B}[50;36R"

        let events = TerminalSurface.parsedSocketInputEvents(
            for: firstOSC11 + firstCPR + secondOSC11 + secondCPR
        )

        #expect(terminalBytePayloads(in: events) == [
            Data(firstOSC11.utf8),
            Data(firstCPR.utf8),
            Data(secondOSC11.utf8),
            Data(secondCPR.utf8),
        ])
        #expect(!containsUserInputEvents(events))
    }

    @Test func terminalCSIProbeRepliesStayTerminalBytes() {
        let replies = [
            "\u{1B}[?1;2c",
            "\u{1B}[>0;95;0c",
            "\u{1B}[0n",
            "\u{1B}[?997;1n",
            "\u{1B}[?0u",
            "\u{1B}[?12;2$y",
            "\u{1B}[4;1$y",
        ]
        let events = TerminalSurface.parsedSocketInputEvents(for: replies.joined())

        #expect(terminalBytePayloads(in: events) == replies.map { Data($0.utf8) })
        #expect(!containsUserInputEvents(events))
    }

    @Test func keyboardProtocolKeyInputDoesNotBecomeTerminalBytes() {
        let events = TerminalSurface.parsedSocketInputEvents(for: "\u{1B}[13;2u")

        #expect(terminalBytePayloads(in: events).isEmpty)
        #expect(containsUserInputEvents(events))
    }

    private func terminalBytePayloads(in events: [ParsedSocketInput]) -> [Data] {
        events.compactMap { event in
            guard case .terminalBytes(let data) = event else {
                return nil
            }
            return data
        }
    }

    private func containsUserInputEvents(_ events: [ParsedSocketInput]) -> Bool {
        events.contains { event in
            switch event {
            case .rawBytes, .key:
                return true
            case .terminalBytes:
                return false
            }
        }
    }
}
