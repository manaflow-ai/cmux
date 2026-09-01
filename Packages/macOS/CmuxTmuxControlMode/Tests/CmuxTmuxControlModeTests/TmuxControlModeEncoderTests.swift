import Testing
import CmuxTerminalCore
@testable import CmuxTmuxControlMode

@Suite("tmux control mode encoder")
struct TmuxControlModeEncoderTests {
    @Test func capturePaneRequestsFullHistoryWithEscapes() {
        #expect(TmuxControlModeEncoder.capturePane(paneID: "%3") == "capture-pane -t %3 -p -e -N -S - -E '-'")
    }

    @Test func sendKeysEncodesBytesAsHex() {
        #expect(TmuxControlModeEncoder.sendKeys(paneID: "%1", bytes: [0x68, 0x69, 0x0D]) == "send-keys -t %1 -H 68 69 0d")
    }

    @Test func sendKeysCommandsBoundLargeInput() {
        let commands = TmuxControlModeEncoder.sendKeysCommands(
            paneID: "%1",
            bytes: Array(repeating: 0x61, count: 5),
            maximumBytesPerCommand: 2
        )
        #expect(commands == [
            "send-keys -t %1 -H 61 61",
            "send-keys -t %1 -H 61 61",
            "send-keys -t %1 -H 61",
        ])
    }

    @Test func namedKeyUsesOneQuotedTmuxToken() {
        #expect(TmuxControlModeEncoder.sendNamedKey(paneID: "%1", keyName: "C-S-Up") == "send-keys -t %1 'C-S-Up'")
        #expect(TmuxControlModeEncoder.sendNamedKey(paneID: "%1", keyName: "End;kill-server") == nil)
    }

    @Test func foregroundSubscriptionUsesStablePaneName() {
        #expect(TmuxControlModeEncoder.queryPaneForeground(paneID: "%3") == "display-message -p -t %3 -F \"#{alternate_on}|#{pane_current_command}\"")
        #expect(TmuxControlModeEncoder.subscribePaneForeground(paneID: "%3") == "refresh-client -B \"cmux_harbor_reflow_3:%3:#{alternate_on}|#{pane_current_command}\"")
    }

    @Test func refreshClientUsesColumnsByRows() {
        #expect(TmuxControlModeEncoder.refreshClientSize(TerminalSize(columns: 120, rows: 40)) == "refresh-client -C 120x40")
    }

    @Test func refreshClientCanTargetOneWindow() {
        #expect(TmuxControlModeEncoder.refreshClientSize(
            TerminalSize(columns: 120, rows: 40),
            windowID: "@7"
        ) == "refresh-client -C '@7:120x40'")
    }

    @Test func terminalSizeClampsToOne() {
        let size = TerminalSize(columns: 0, rows: -5)
        #expect(size.columns == 1)
        #expect(size.rows == 1)
    }

    @Test func localControlModeUsesThePtyApplicationMode() {
        let arguments = TmuxControlModeGateway.localControlModeArguments(
            tmuxExecutablePath: "/opt/homebrew/bin/tmux",
            target: .pane(sessionName: "dev's", windowID: 4, paneID: 9)
        )
        #expect(arguments == [
            "-q", "-F", "-", "/usr/bin/env", "-u", "TMUX", "-u", "TMUX_PANE", "TERM=xterm-256color",
            "/opt/homebrew/bin/tmux", "-u", "-CC",
            "attach-session", "-t", "=dev's:@4.%9",
        ])
    }

    @Test func remoteHerdrControlUsesTransparentSSHWithoutRemoteClientMode() {
        let arguments = HerdrControlModeGateway.remoteArguments(
            destination: "user@host",
            sessionName: "work space",
            target: "w1:p1",
            size: TerminalSize(columns: 120, rows: 40)
        )
        #expect(arguments == [
            "-T", "-o", "EscapeChar=none", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "--",
            "user@host",
            "herdr --session 'work space' terminal session control 'w1:p1' --takeover --cols '120' --rows '40'",
        ])
    }

    @Test func paneTargetIsFullyQualifiedAndExact() {
        let target = TmuxAttachTarget.pane(sessionName: "dev", windowID: 4, paneID: 9)
        #expect(target.targetExpression == "=dev:@4.%9")
        #expect(target.tmuxArguments == ["attach-session", "-t", "=dev:@4.%9"])
    }

    @Test func herdrScrollLineUsesSemanticFields() {
        let command = TerminalScrollCommand(
            direction: .down,
            lines: 3,
            source: .wheel,
            column: 11,
            row: 7,
            modifiers: 5
        )!
        #expect(
            String(decoding: HerdrControlModeGateway.scrollLine(command), as: UTF8.self)
                == #"{"type":"terminal.scroll","direction":"down","lines":3,"source":"wheel","column":11,"row":7,"modifiers":5}"# + "\n"
        )
    }

    @Test func herdrPageKeyScrollUsesPageKeySource() {
        let command = TerminalScrollCommand(
            direction: .up,
            lines: 23,
            source: .pageKey
        )!
        #expect(
            String(decoding: HerdrControlModeGateway.scrollLine(command), as: UTF8.self)
                == #"{"type":"terminal.scroll","direction":"up","lines":23,"source":"page_key","modifiers":0}"# + "\n"
        )
    }

    @Test("Herdr input records are bounded and preserve byte order")
    func herdrInputLinesChunkLargePayload() throws {
        let bytes = Array(0..<11).map(UInt8.init)
        let lines = HerdrControlModeGateway.inputLines(bytes: bytes, maximumBytesPerRecord: 4)
        #expect(lines.count == 3)
        let decoder = JSONDecoder()
        struct Record: Decodable { let type: String; let bytes: String }
        var decoded: [UInt8] = []
        for line in lines {
            let record = try decoder.decode(Record.self, from: Data(line.dropLast()))
            #expect(record.type == "terminal.input")
            decoded.append(contentsOf: Data(base64Encoded: record.bytes) ?? [])
        }
        #expect(decoded == bytes)
    }
}
