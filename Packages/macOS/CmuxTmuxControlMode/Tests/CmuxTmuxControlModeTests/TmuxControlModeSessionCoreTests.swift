import Testing
@testable import CmuxTmuxControlMode

@Suite("tmux control mode session core")
struct TmuxControlModeSessionCoreTests {
    private typealias Effect = TmuxControlModeSessionCore.Effect

    private func commands(_ effects: [Effect]) -> [String] {
        effects.compactMap { effect in
            guard case let .write(bytes) = effect else { return nil }
            return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: ["\n"])
        }
    }

    private func bytes(_ effects: [Effect]) -> (
        snapshots: [[UInt8]],
        outputs: [[UInt8]],
        ended: [String?],
        failed: [String]
    ) {
        var snapshots: [[UInt8]] = []
        var outputs: [[UInt8]] = []
        var ended: [String?] = []
        var failed: [String] = []
        for effect in effects {
            switch effect {
            case let .snapshot(value): snapshots.append(value)
            case let .output(value): outputs.append(value)
            case let .ended(reason): ended.append(reason)
            case let .failed(reason): failed.append(reason)
            case .resizePolicy: break
            case .write: break
            }
        }
        return (snapshots, outputs, ended, failed)
    }

    private func policies(_ effects: [Effect]) -> [TerminalSessionResizePolicy] {
        effects.compactMap { effect in
            guard case let .resizePolicy(policy) = effect else { return nil }
            return policy
        }
    }

    private func response(
        _ number: Int,
        lines: [String] = [],
        error: Bool = false
    ) -> [UInt8] {
        let fence = error ? "%error" : "%end"
        var text = "%begin 1 \(number) 1\n"
        if !lines.isEmpty { text += lines.joined(separator: "\n") + "\n" }
        text += "\(fence) 1 \(number) 1\n"
        return Array(text.utf8)
    }

    private let stateLine = "cursor_x=2,cursor_y=1,scroll_region_upper=0,scroll_region_lower=23,cursor_flag=1,insert_flag=0,keypad_cursor_flag=0,keypad_flag=0,wrap_flag=1,origin_flag=0,pane_height=24,mouse_all_flag=0,mouse_button_flag=0,mouse_standard_flag=0,mouse_sgr_flag=0,mouse_utf8_flag=0"

    @Test("explicit pane starts a flow-controlled, stateful capture transaction")
    func explicitPaneStartsWithCaptureAndSkipsActivePaneDiscovery() {
        var core = TmuxControlModeSessionCore(targetPaneID: "%9", targetWindowID: "@4")
        let effects = core.start(initialSize: TerminalSize(columns: 80, rows: 24))
        #expect(commands(effects) == [
            TmuxControlModeEncoder.enableFlowControl(),
            TmuxControlModeEncoder.refreshClientSize(TerminalSize(columns: 80, rows: 24), windowID: "@4"),
            TmuxControlModeEncoder.pausePaneOutput(paneID: "%9"),
            TmuxControlModeEncoder.queryPaneForeground(paneID: "%9"),
            TmuxControlModeEncoder.capturePane(paneID: "%9"),
            TmuxControlModeEncoder.queryPaneState(paneID: "%9"),
            TmuxControlModeEncoder.continuePaneOutput(paneID: "%9"),
        ])
    }

    @Test func startNegotiatesSizeThenResolvesPane() {
        var core = TmuxControlModeSessionCore()
        let started = core.start(initialSize: TerminalSize(columns: 80, rows: 24))
        #expect(commands(started) == [
            TmuxControlModeEncoder.enableFlowControl(),
            TmuxControlModeEncoder.refreshClientSize(TerminalSize(columns: 80, rows: 24)),
            TmuxControlModeEncoder.listActivePanes(),
        ])
    }

    @Test func fullAttachFlowResolvesPaneCapturesAndSnapshots() {
        var core = TmuxControlModeSessionCore()
        _ = core.start(initialSize: TerminalSize(columns: 80, rows: 24))
        _ = core.consume(response(0)) // attach handshake
        _ = core.consume(response(1)) // flow control
        _ = core.consume(response(2)) // client size
        let seedCommands = core.consume(response(3, lines: ["1:%5", "0:%6"]))
        #expect(commands(seedCommands) == [
            TmuxControlModeEncoder.pausePaneOutput(paneID: "%5"),
            TmuxControlModeEncoder.queryPaneForeground(paneID: "%5"),
            TmuxControlModeEncoder.capturePane(paneID: "%5"),
            TmuxControlModeEncoder.queryPaneState(paneID: "%5"),
            TmuxControlModeEncoder.continuePaneOutput(paneID: "%5"),
        ])

        _ = core.consume(response(4)) // pause
        _ = core.consume(response(5, lines: ["1"])) // alternate screen
        _ = core.consume(response(6, lines: ["row1", "row2"])) // capture
        let result = bytes(core.consume(response(7, lines: [stateLine]))) // state
        _ = core.consume(response(8)) // continue
        #expect(result.snapshots.count == 1)
        let snapshot = String(decoding: result.snapshots[0], as: UTF8.self)
        #expect(snapshot.contains("\u{1b}c\u{1b}[3J\u{1b}[?1049l\u{1b}[?1049h"))
        #expect(snapshot.contains("row1\r\nrow2"))
        #expect(snapshot.hasSuffix("\u{1b}[2;3H"))
    }

    @Test("the attach handshake is an explicit command boundary")
    func attachHandshakeIsExplicit() {
        var core = TmuxControlModeSessionCore(targetPaneID: "%5")
        #expect(!core.attachHandshakeComplete)
        _ = core.start(initialSize: TerminalSize(columns: 80, rows: 24))
        #expect(!core.attachHandshakeComplete)
        _ = core.consume(response(17))
        #expect(core.attachHandshakeComplete)
    }

    @Test func outputBeforePauseIsCoveredByCaptureAndLaterOutputIsLive() {
        var core = TmuxControlModeSessionCore(targetPaneID: "%5", targetWindowID: "@2")
        _ = core.start(initialSize: TerminalSize(columns: 80, rows: 24))
        _ = core.consume(response(0)) // attach
        _ = core.consume(response(1)) // flow control
        _ = core.consume(response(2)) // size
        #expect(bytes(core.consume(Array("%output %5 early\n".utf8))).outputs.isEmpty)
        _ = core.consume(response(3)) // pause, drops pre-boundary bytes
        _ = core.consume(response(4, lines: ["0"]))
        _ = core.consume(response(5, lines: ["screen"]))
        let snapshot = bytes(core.consume(response(6, lines: [stateLine])))
        #expect(snapshot.snapshots.count == 1)
        _ = core.consume(response(7))
        let live = core.consume(Array("%output %5 more\n".utf8))
        #expect(bytes(live).outputs == [Array("more".utf8)])
    }

    @Test func sendInputEncodesSendKeysForResolvedPane() {
        var core = TmuxControlModeSessionCore(targetPaneID: "%5")
        _ = core.start(initialSize: TerminalSize(columns: 80, rows: 24))
        _ = core.consume(response(0))
        _ = core.consume(response(1))
        _ = core.consume(response(2))
        _ = core.consume(response(3))
        _ = core.consume(response(4, lines: ["0|zsh"]))
        _ = core.consume(response(5, lines: ["screen"]))
        _ = core.consume(response(6, lines: [stateLine]))
        let resume = core.consume(response(7))
        #expect(commands(resume) == [TmuxControlModeEncoder.subscribePaneForeground(paneID: "%5")])
        #expect(commands(core.sendInput([0x68, 0x69])) == ["send-keys -t %5 -H 68 69"])
    }

    @Test("large input is split into bounded tmux commands")
    func largeInputIsChunked() {
        var core = TmuxControlModeSessionCore(targetPaneID: "%5")
        _ = core.start(initialSize: TerminalSize(columns: 80, rows: 24))
        _ = core.consume(response(0))
        _ = core.consume(response(1))
        _ = core.consume(response(2))
        _ = core.consume(response(3))
        _ = core.consume(response(4, lines: ["0|zsh"]))
        _ = core.consume(response(5, lines: ["screen"]))
        _ = core.consume(response(6, lines: [stateLine]))
        _ = core.consume(response(7))
        let effects = core.sendInput(Array(repeating: 0x61, count: 4097))
        let encoded = commands(effects)
        #expect(encoded.count == 2)
        #expect(encoded.allSatisfy { $0.hasPrefix("send-keys -t %5 -H ") })
    }

    @Test func namedInputUsesTmuxKeyTable() {
        var core = TmuxControlModeSessionCore(targetPaneID: "%5")
        _ = core.start(initialSize: TerminalSize(columns: 80, rows: 24))
        _ = core.consume(response(0))
        _ = core.consume(response(1))
        _ = core.consume(response(2))
        _ = core.consume(response(3))
        _ = core.consume(response(4, lines: ["0|zsh"]))
        _ = core.consume(response(5, lines: ["screen"]))
        _ = core.consume(response(6, lines: [stateLine]))
        _ = core.consume(response(7))
        #expect(commands(core.sendNamedKey("C-S-Up")) == ["send-keys -t %5 'C-S-Up'"])
        #expect(core.sendNamedKey("bad;command").isEmpty)
    }

    @Test("input waits behind the initial replacement snapshot")
    func inputIsNotWrittenDuringSeed() {
        var core = TmuxControlModeSessionCore(targetPaneID: "%5")
        _ = core.start(initialSize: TerminalSize(columns: 80, rows: 24))
        #expect(core.sendInput([0x61]).isEmpty)
        _ = core.consume(response(0))
        _ = core.consume(response(1))
        _ = core.consume(response(2))
        _ = core.consume(response(3))
        _ = core.consume(response(4, lines: ["0|zsh"]))
        _ = core.consume(response(5, lines: ["screen"]))
        let state = core.consume(response(6, lines: [stateLine]))
        #expect(commands(state).isEmpty)
        let resume = core.consume(response(7))
        #expect(commands(resume).contains("send-keys -t %5 -H 61"))
    }

    @Test func foregroundQueryPublishesPolicyAndLiveSubscriptionUpdatesIt() {
        var core = TmuxControlModeSessionCore(targetPaneID: "%5")
        _ = core.start(initialSize: TerminalSize(columns: 80, rows: 24))
        _ = core.consume(response(0))
        _ = core.consume(response(1))
        _ = core.consume(response(2))
        _ = core.consume(response(3)) // pause
        #expect(policies(core.consume(response(4, lines: ["0|zsh"]))) == [.reflow])
        _ = core.consume(response(5, lines: ["screen"]))
        _ = core.consume(response(6, lines: [stateLine]))
        let resume = core.consume(response(7)) // continue
        #expect(commands(resume) == [TmuxControlModeEncoder.subscribePaneForeground(paneID: "%5")])
        let subscription = core.consume(response(8))
        #expect(commands(subscription) == [])
        #expect(policies(core.consume(Array("%subscription-changed cmux_harbor_reflow_5 1 @0 %5 : 1|nvim\n".utf8))) == [.preserveScreen])
    }

    @Test("a rejected foreground subscription is not retried forever")
    func foregroundSubscriptionFailureDisablesOptionalSubscription() {
        var core = TmuxControlModeSessionCore(targetPaneID: "%5")
        _ = core.start(initialSize: TerminalSize(columns: 80, rows: 24))
        _ = core.consume(response(0))
        _ = core.consume(response(1))
        _ = core.consume(response(2))
        _ = core.consume(response(3))
        _ = core.consume(response(4, lines: ["0|zsh"]))
        _ = core.consume(response(5, lines: ["screen"]))
        _ = core.consume(response(6, lines: [stateLine]))
        _ = core.consume(response(7))
        let subscriptionError = core.consume(response(8, lines: ["unsupported"], error: true))
        #expect(commands(subscriptionError).isEmpty)

        _ = core.consume(Array("%pause %5\n".utf8))
        _ = core.consume(response(9, lines: ["0|zsh"]))
        _ = core.consume(response(10, lines: ["screen"]))
        _ = core.consume(response(11, lines: [stateLine]))
        let resume = core.consume(response(12))
        #expect(commands(resume).isEmpty)
    }

    @Test("coalesces resize intent behind the tmux acknowledgement")
    func resizeIsLatestWins() {
        var core = TmuxControlModeSessionCore(targetPaneID: "%9", targetWindowID: "@4")
        _ = core.start(initialSize: TerminalSize(columns: 80, rows: 24))
        #expect(core.resize(TerminalSize(columns: 90, rows: 25)).isEmpty)
        #expect(core.resize(TerminalSize(columns: 100, rows: 30)).isEmpty)
        _ = core.consume(response(0)) // attach
        _ = core.consume(response(1)) // flow control
        let latest = core.consume(response(2)) // initial size
        #expect(commands(latest) == ["refresh-client -C '@4:100x30'"])
        #expect(core.resize(TerminalSize(columns: 110, rows: 32)).isEmpty)
        _ = core.consume(response(3)) // pause
        _ = core.consume(response(4, lines: ["0"]))
        _ = core.consume(response(5, lines: ["screen"]))
        _ = core.consume(response(6, lines: [stateLine]))
        _ = core.consume(response(7)) // resume
        let final = core.consume(response(8)) // coalesced resize
        #expect(commands(final) == ["refresh-client -C '@4:110x32'"])
    }

    @Test("a flow-control pause triggers an authoritative replacement capture")
    func pauseNotificationReseedsWithoutASecondPause() {
        var core = TmuxControlModeSessionCore(targetPaneID: "%5")
        _ = core.start(initialSize: TerminalSize(columns: 80, rows: 24))
        _ = core.consume(response(0))
        _ = core.consume(response(1))
        _ = core.consume(response(2))
        _ = core.consume(response(3))
        _ = core.consume(response(4, lines: ["0"]))
        _ = core.consume(response(5, lines: ["first"]))
        let first = bytes(core.consume(response(6, lines: [stateLine])))
        #expect(first.snapshots.count == 1)
        _ = core.consume(response(7))
        _ = core.consume(response(8)) // foreground subscription

        let recovery = core.consume(Array("%pause %5\n".utf8))
        #expect(commands(recovery) == [
            TmuxControlModeEncoder.queryPaneForeground(paneID: "%5"),
            TmuxControlModeEncoder.capturePane(paneID: "%5"),
            TmuxControlModeEncoder.queryPaneState(paneID: "%5"),
            TmuxControlModeEncoder.continuePaneOutput(paneID: "%5"),
        ])
        _ = core.consume(response(9, lines: ["0|zsh"]))
        _ = core.consume(response(10, lines: ["second"]))
        let result = bytes(core.consume(response(11, lines: [stateLine])))
        #expect(result.snapshots.count == 1)
        #expect(String(decoding: result.snapshots[0], as: UTF8.self).contains("second"))
        _ = core.consume(response(12))
    }

    @Test func explicitPaneResizeTargetsItsWindow() {
        var core = TmuxControlModeSessionCore(targetPaneID: "%9", targetWindowID: "@4")
        _ = core.start(initialSize: TerminalSize(columns: 80, rows: 24))
        _ = core.resize(TerminalSize(columns: 100, rows: 30))
        _ = core.consume(response(0))
        _ = core.consume(response(1))
        #expect(commands(core.consume(response(2))) == ["refresh-client -C '@4:100x30'"])
    }

    @Test func exitEndsSession() {
        var core = TmuxControlModeSessionCore()
        _ = core.start(initialSize: TerminalSize(columns: 80, rows: 24))
        let ended = bytes(core.consume(Array("%exit gone\n".utf8))).ended
        #expect(ended == ["gone"])
        #expect(core.sendInput([0x61]).isEmpty)
    }

    @Test func gatewayExitEndsSession() {
        var core = TmuxControlModeSessionCore()
        _ = core.start(initialSize: TerminalSize(columns: 80, rows: 24))
        let ended = bytes(core.gatewayExited(reason: "tmux exited (1)")).ended
        #expect(ended == ["tmux exited (1)"])
    }

    @Test("transport failure stays distinct from a pane exit")
    func gatewayFailureReportsFailure() {
        var core = TmuxControlModeSessionCore()
        _ = core.start(initialSize: TerminalSize(columns: 80, rows: 24))
        let result = bytes(core.gatewayFailed(reason: "socket closed"))
        #expect(result.ended.isEmpty)
        #expect(result.failed == ["socket closed"])
    }

    @Test func paneDiscoveryWithoutAnyPaneEndsSession() {
        var core = TmuxControlModeSessionCore()
        _ = core.start(initialSize: TerminalSize(columns: 80, rows: 24))
        _ = core.consume(response(0))
        _ = core.consume(response(1))
        _ = core.consume(response(2))
        let result = bytes(core.consume(response(3)))
        #expect(result.ended == ["no active tmux pane"])
    }

    @Test("a pane discovery command error is a failure, not a clean end")
    func paneDiscoveryErrorReportsFailure() {
        var core = TmuxControlModeSessionCore()
        _ = core.start(initialSize: TerminalSize(columns: 80, rows: 24))
        _ = core.consume(response(0))
        _ = core.consume(response(1))
        _ = core.consume(response(2))
        let result = bytes(core.consume(response(3, lines: ["no panes"], error: true)))
        #expect(result.ended.isEmpty)
        #expect(result.failed == ["no panes"])
    }

    @Test("resize and resume command errors are surfaced")
    func commandErrorsDoNotSilentlyContinue() {
        var resizeCore = TmuxControlModeSessionCore(targetPaneID: "%5")
        _ = resizeCore.start(initialSize: TerminalSize(columns: 80, rows: 24))
        _ = resizeCore.consume(response(0))
        _ = resizeCore.consume(response(1))
        let resizeResult = bytes(resizeCore.consume(response(2, lines: ["bad size"], error: true)))
        #expect(resizeResult.failed == ["bad size"])

        var resumeCore = TmuxControlModeSessionCore(targetPaneID: "%5")
        _ = resumeCore.start(initialSize: TerminalSize(columns: 80, rows: 24))
        _ = resumeCore.consume(response(0))
        _ = resumeCore.consume(response(1))
        _ = resumeCore.consume(response(2))
        _ = resumeCore.consume(response(3))
        _ = resumeCore.consume(response(4, lines: ["0"]))
        _ = resumeCore.consume(response(5, lines: ["screen"]))
        _ = resumeCore.consume(response(6, lines: [stateLine]))
        let resumeResult = bytes(resumeCore.consume(response(7, lines: ["cannot continue"], error: true)))
        #expect(resumeResult.failed == ["cannot continue"])
    }

    @Test func attachErrorFailsBeforeCommandFifo() {
        var core = TmuxControlModeSessionCore()
        _ = core.start(initialSize: TerminalSize(columns: 80, rows: 24))
        let result = bytes(core.consume(response(0, lines: ["can't attach"], error: true)))
        #expect(result.ended.isEmpty)
        #expect(result.failed == ["can't attach"])
    }

    @Test func snapshotErrorFailsAfterResumingThePausedPane() {
        var core = TmuxControlModeSessionCore(targetPaneID: "%5", targetWindowID: "@2")
        _ = core.start(initialSize: TerminalSize(columns: 80, rows: 24))
        _ = core.consume(response(0))
        _ = core.consume(response(1))
        _ = core.consume(response(2))
        _ = core.consume(response(3)) // pause
        _ = core.consume(response(4, lines: ["0"]))
        _ = core.consume(response(5, lines: ["can't capture"], error: true))
        _ = core.consume(response(6)) // state
        let result = bytes(core.consume(response(7))) // resume
        #expect(result.snapshots.isEmpty)
        #expect(result.ended.isEmpty)
        #expect(result.failed == ["can't capture"])
    }

    @Test("rejects a response that cannot be correlated to the command FIFO")
    func unsolicitedResponseFailsSession() {
        var core = TmuxControlModeSessionCore(targetPaneID: "%5")
        _ = core.start(initialSize: TerminalSize(columns: 80, rows: 24))
        _ = core.consume(response(0)) // attach handshake
        for _ in 0..<8 {
            _ = core.consume(response(0))
        }
        let result = bytes(core.consume(response(0)))
        #expect(result.ended.isEmpty)
        #expect(result.failed == ["tmux returned an unsolicited command response"])
    }

    @Test("accepts response numbers that are not monotonic")
    func nonMonotonicResponseNumbersAreCorrelatedByFifo() {
        var core = TmuxControlModeSessionCore(targetPaneID: "%5")
        _ = core.start(initialSize: TerminalSize(columns: 80, rows: 24))
        _ = core.consume(response(100)) // attach handshake
        _ = core.consume(response(2)) // flow control
        let resize = core.consume(response(1)) // client size
        #expect(commands(resize).isEmpty)
        #expect(core.attachHandshakeComplete)
    }
}
