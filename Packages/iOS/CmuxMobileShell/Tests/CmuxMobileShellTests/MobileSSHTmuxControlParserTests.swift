@testable import CmuxMobileShell
import Foundation
import Testing

struct MobileSSHTmuxControlParserTests {
    private func feed(_ text: String, chunked: Int? = nil) -> [MobileSSHTmuxControlMessage] {
        var parser = MobileSSHTmuxControlParser()
        let bytes = Data(text.utf8)
        guard let chunked else { return parser.feed(bytes) }
        var messages: [MobileSSHTmuxControlMessage] = []
        var index = 0
        while index < bytes.count {
            messages += parser.feed(bytes.subdata(in: index..<min(bytes.count, index + chunked)))
            index += chunked
        }
        return messages
    }

    @Test func outputIsOctalUnescaped() {
        let messages = feed("%output %3 a\\033[1mb\\015\\012\\134x\n")
        #expect(messages == [.output(pane: 3, data: Data("a\u{1B}[1mb\r\n\\x".utf8))])
    }

    @Test func outputKeepsSplitUTF8Bytes() {
        // "é" is C3 A9; tmux can split it across two notifications.
        var parser = MobileSSHTmuxControlParser()
        var line1 = Data("%output %1 ".utf8); line1.append(0xC3); line1.append(0x0A)
        var line2 = Data("%output %1 ".utf8); line2.append(0xA9); line2.append(0x0A)
        var joined = Data()
        for message in parser.feed(line1) + parser.feed(line2) {
            if case .output(_, let data) = message { joined.append(data) }
        }
        #expect(String(decoding: joined, as: UTF8.self) == "é")
    }

    @Test func unescapeLeavesMalformedEscapes() {
        #expect(MobileSSHTmuxControlParser.unescape(Array("\\777\\01\\".utf8)) == Data("\\777\\01\\".utf8))
        #expect(MobileSSHTmuxControlParser.unescape(Array("\\101".utf8)) == Data("A".utf8))
    }

    @Test func beginEndFramesReplyWithFlags() {
        let messages = feed("%begin 1 12 0\n%end 1 12 0\n%begin 1 13 1\nline one\n%end 1 99 1\n\n%end 1 13 1\n", chunked: 5)
        #expect(messages == [
            .reply(number: 12, flags: 0, lines: [], isError: false),
            .reply(number: 13, flags: 1, lines: [Data("line one".utf8), Data("%end 1 99 1".utf8), Data()], isError: false),
        ])
    }

    @Test func errorBlockAndNotificationsInsideBlockAreContent() {
        let messages = feed("%begin 5 7 1\n%pause %0\n%output %0 x\n%error 5 7 1\n")
        #expect(messages == [.reply(number: 7, flags: 1, lines: [Data("%pause %0".utf8), Data("%output %0 x".utf8)], isError: true)])
    }

    @Test func notifications() {
        let messages = feed("""
        %window-add @4
        %unlinked-window-add @9
        %window-close @4
        %unlinked-window-close @9
        %window-renamed @2 my window
        %layout-change @1 3df5,80x20,0,0{40x20,0,0,0,39x20,41,0,1} 3df5,80x20,0,0{40x20,0,0,0,39x20,41,0,1} *
        %session-changed $3 work space
        %sessions-changed
        %session-window-changed $3 @2
        %window-pane-changed @2 %7
        %pane-mode-changed %7
        %exit detached

        """)
        #expect(messages == [
            .windowAdd(window: 4),
            .other("%unlinked-window-add @9"),
            .windowClose(window: 4),
            .other("%unlinked-window-close @9"),
            .windowRenamed(window: 2, name: "my window"),
            .layoutChange(window: 1, layout: "3df5,80x20,0,0{40x20,0,0,0,39x20,41,0,1}", visibleLayout: "3df5,80x20,0,0{40x20,0,0,0,39x20,41,0,1}"),
            .sessionChanged(session: 3, name: "work space"),
            .sessionsChanged,
            .sessionWindowChanged(session: 3, window: 2),
            .windowPaneChanged(window: 2, pane: 7),
            .paneModeChanged(pane: 7),
            .exit(reason: "detached"),
        ])
    }

    @Test func layoutLeaves() {
        let nested = MobileSSHTmuxLayout("b25f,160x40,0,0[160x20,0,0{80x20,0,0,1,79x20,81,0,2},160x19,0,21,3]").leaves
        #expect(nested.map(\.pane) == [1, 2, 3])
        #expect(nested.map(\.columns) == [80, 79, 160])
        #expect(nested.map(\.rows) == [20, 20, 19])
        #expect(MobileSSHTmuxLayout("a25f,80x20,0,0,12").leaves == [.init(pane: 12, columns: 80, rows: 20, x: 0, y: 0)])
    }

    @Test func stateSequencePlacesCursorLastAndRestoresRegion() {
        let fields = MobileSSHTmuxControlClient.fields("cursor_x=4,cursor_y=9,scroll_region_upper=2,scroll_region_lower=10,cursor_flag=1,wrap_flag=1,origin_flag=0,pane_height=24,mouse_button_flag=1,mouse_sgr_flag=1")
        let sequence = String(decoding: MobileSSHTmuxControlClient.stateSequence(fields), as: UTF8.self)
        #expect(sequence.contains("\u{1B}[3;11r"))
        #expect(sequence.contains("\u{1B}[?1002h\u{1B}[?1006h"))
        #expect(sequence.hasSuffix("\u{1B}[10;5H"))
    }

    @Test func workspacesGroupPanesAndHideGroupedSessions() {
        let output = [
            "work:1:1:%5:0:logs: tail",
            "work:0:2:%2:1:zsh",
            "work:0:2:%1:0:zsh",
            "work-cmux-ios-abcd1234:0:2:%1:0:zsh",
            "other:0:1:%9:0:vim",
        ].joined(separator: "\n")
        let workspaces = MobileSSHTmuxProvider.workspaces(from: MobileSSHTmuxProvider.parsePaneRows(output))
        #expect(workspaces.map(\.id) == ["work", "other"])
        #expect(workspaces[0].terminals.map(\.id) == ["work/%1", "work/%2", "work/%5"])
        #expect(workspaces[0].terminals.map(\.name) == ["0:zsh · pane 1", "0:zsh · pane 2", "1:logs: tail"])
        #expect(MobileSSHTmuxProvider.parseTerminalID("a/b/%12")! == ("a/b", 12))
    }

    // MARK: Screen title sequences

    private func filtered(_ chunks: [String]) -> (output: String, titles: [String]) {
        var filter = MobileSSHTmuxTitleSequenceFilter()
        var output = Data()
        var titles: [String] = []
        for chunk in chunks {
            let result = filter.filter(Data(chunk.utf8))
            output.append(result.output)
            titles += result.titles
        }
        return (String(decoding: output, as: UTF8.self), titles)
    }

    /// zsh under tmux emits `ESC k <title> ESC \` (laptop log:
    /// `%output %56 \033k/tmp\033\134`); it rendered as a stray "/tmp" line.
    @Test func screenTitleSequenceIsRemoved() {
        let result = filtered(["a\u{1B}k/tmp\u{1B}\\b"])
        #expect(result.output == "ab")
        #expect(result.titles == ["/tmp"])
    }

    @Test func screenTitleSplitAcrossEveryChunkBoundaryIsRemoved() {
        let text = "prompt \u{1B}k..w/cmuxterm-hq\u{1B}\\% \u{1B}[1mbold\u{1B}[0m"
        let bytes = Array(text.utf8)
        for split in 1..<bytes.count {
            var filter = MobileSSHTmuxTitleSequenceFilter()
            var output = filter.filter(Data(bytes[..<split])).output
            output.append(filter.filter(Data(bytes[split...])).output)
            #expect(String(decoding: output, as: UTF8.self) == "prompt % \u{1B}[1mbold\u{1B}[0m", "split at \(split)")
        }
        // One byte per chunk.
        #expect(filtered(text.map(String.init)).output == "prompt % \u{1B}[1mbold\u{1B}[0m")
    }

    @Test func screenTitleEndsOnBELAndOtherEscapesPassThrough() {
        let result = filtered(["\u{1B}kvim\u{07}\u{1B}]0;osc\u{07}\u{1B}[2J\u{1B}\u{1B}[m"])
        #expect(result.titles == ["vim"])
        #expect(result.output == "\u{1B}]0;osc\u{07}\u{1B}[2J\u{1B}\u{1B}[m")
    }

    @Test func escapeAtChunkEndIsHeldUntilTheNextByte() {
        var filter = MobileSSHTmuxTitleSequenceFilter()
        #expect(filter.filter(Data("x\u{1B}".utf8)).output == Data("x".utf8))
        #expect(filter.filter(Data("[A".utf8)).output == Data("\u{1B}[A".utf8))
    }

    @Test func unterminatedTitleEndedByAnotherEscapeKeepsThatEscape() {
        let result = filtered(["\u{1B}kname\u{1B}[31mred"])
        #expect(result.titles == ["name"])
        #expect(result.output == "\u{1B}[31mred")
    }

    // MARK: Grouped sessions

    /// The control client's start command creates and attaches its grouped
    /// session in one step and turns tmux's `destroy-unattached` OFF for it:
    /// that option crashed tmux 3.7c when two phone clients dropped at once.
    @Test func startCommandNeverAsksTmuxToDestroyTheGroupedSession() {
        let command = MobileSSHTmuxControlClient.startCommand(tmux: "'/opt/homebrew/bin/tmux'", session: "vt-main", grouped: "vt-main-cmux-ios-abcd1234")
        #expect(command.hasPrefix("'/opt/homebrew/bin/tmux' -C new-session -t '=vt-main' -s 'vt-main-cmux-ios-abcd1234'"))
        #expect(command.hasSuffix(" \\; set-option -t '=vt-main-cmux-ios-abcd1234:' destroy-unattached off"))
        #expect(!command.contains("destroy-unattached on"))
        #expect(!command.contains("switch-client"))
    }

    @Test func staleGroupedSessionsAreUnattachedPhoneSessionsOnly() {
        let output = [
            "0:vt-main-cmux-ios-dead0001",
            "1:vt-main-cmux-ios-live0002",
            "0:vt-main",
            "2:work",
            "0:odd:name-cmux-ios-dead0003",
            "garbage",
        ].joined(separator: "\n")
        #expect(MobileSSHTmuxProvider.staleGroupedSessions(output) == ["vt-main-cmux-ios-dead0001", "odd:name-cmux-ios-dead0003"])
    }
}
