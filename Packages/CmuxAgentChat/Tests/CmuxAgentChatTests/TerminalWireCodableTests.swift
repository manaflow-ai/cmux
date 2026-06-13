import Foundation
import Testing

@testable import CmuxAgentChat

@Suite("Terminal wire codable")
struct TerminalWireCodableTests {
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    @Test("TerminalCommandBlock round-trips through JSON with snake_case keys")
    func blockRoundTrip() throws {
        let block = TerminalCommandBlock(
            id: 3, command: "npm test", output: "ok\n",
            exitCode: 1, isRunning: false, isInteractive: true
        )
        let data = try encoder.encode(block)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"exit_code\""))
        #expect(json.contains("\"is_running\""))
        #expect(json.contains("\"is_interactive\""))
        #expect(try decoder.decode(TerminalCommandBlock.self, from: data) == block)
    }

    @Test("a running block (nil exit) round-trips")
    func runningBlockRoundTrip() throws {
        let block = TerminalCommandBlock(id: 0, command: "tail -f", output: "...", exitCode: nil, isRunning: true)
        let data = try encoder.encode(block)
        #expect(try decoder.decode(TerminalCommandBlock.self, from: data) == block)
    }

    @Test("ChatSessionEvent.terminalBlocks round-trips")
    func eventRoundTrip() throws {
        let event = ChatSessionEvent.terminalBlocks([
            TerminalCommandBlock(id: 0, command: "ls", output: "a\n", exitCode: 0, isRunning: false),
            TerminalCommandBlock(id: 1, command: "pwd", output: "/tmp\n", exitCode: 0, isRunning: false),
        ])
        let data = try encoder.encode(event)
        #expect(String(decoding: data, as: UTF8.self).contains("\"terminal_blocks\""))
        #expect(try decoder.decode(ChatSessionEvent.self, from: data) == event)
    }

    @Test("ChatHistoryPage carries terminal blocks and stays backward-compatible")
    func historyPageTerminal() throws {
        let page = ChatHistoryPage(
            messages: [], hasMore: false,
            terminalBlocks: [TerminalCommandBlock(id: 0, command: "echo hi", output: "hi\n", exitCode: 0, isRunning: false)]
        )
        let data = try encoder.encode(page)
        #expect(try decoder.decode(ChatHistoryPage.self, from: data) == page)
        // An agent-era payload without the terminal_blocks key still decodes.
        let agentJSON = #"{"messages":[],"has_more":true}"#.data(using: .utf8)!
        let decoded = try decoder.decode(ChatHistoryPage.self, from: agentJSON)
        #expect(decoded.terminalBlocks == nil)
        #expect(decoded.hasMore == true)
    }
}
