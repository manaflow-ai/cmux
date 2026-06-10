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

    private func bytes(_ effects: [Effect]) -> (snapshots: [[UInt8]], outputs: [[UInt8]], ended: [String?]) {
        var snapshots: [[UInt8]] = []
        var outputs: [[UInt8]] = []
        var ended: [String?] = []
        for effect in effects {
            switch effect {
            case let .snapshot(b): snapshots.append(b)
            case let .output(b): outputs.append(b)
            case let .ended(r): ended.append(r)
            case .write: break
            }
        }
        return (snapshots, outputs, ended)
    }

    @Test func startNegotiatesSizeThenResolvesPane() {
        var core = TmuxControlModeSessionCore()
        let started = core.start(initialSize: TerminalSize(columns: 80, rows: 24))
        #expect(commands(started) == [
            "refresh-client -C 80x24",
            "list-panes -F '#{pane_active}:#{pane_id}'",
        ])
    }

    @Test func fullAttachFlowResolvesPaneCapturesAndSnapshots() {
        var core = TmuxControlModeSessionCore()
        _ = core.start(initialSize: TerminalSize(columns: 80, rows: 24))

        // refresh-client response (ignored).
        let afterRefresh = core.consume(Array("%begin 1 1 0\n%end 1 1 0\n".utf8))
        #expect(commands(afterRefresh).isEmpty)

        // list-panes response -> capture-pane the active pane (%5).
        let afterList = core.consume(Array("%begin 2 2 0\n1:%5\n0:%6\n%end 2 2 0\n".utf8))
        #expect(commands(afterList) == ["capture-pane -t %5 -p -e -J -S - -E -"])

        // capture-pane response -> snapshot.
        let afterCapture = core.consume(Array("%begin 3 3 0\nrow1\nrow2\n%end 3 3 0\n".utf8))
        let result = bytes(afterCapture)
        #expect(result.snapshots == [Array("row1\r\nrow2".utf8)])
    }

    @Test func liveOutputBeforeSnapshotIsDiscardedNotDuplicated() {
        var core = TmuxControlModeSessionCore()
        _ = core.start(initialSize: TerminalSize(columns: 80, rows: 24))
        _ = core.consume(Array("%begin 1 1 0\n%end 1 1 0\n".utf8))          // refresh-client
        _ = core.consume(Array("%begin 2 2 0\n1:%5\n%end 2 2 0\n".utf8))    // list-panes -> capture-pane queued

        // Pre-snapshot output is already reflected in capture-pane, so it must
        // not be replayed after the snapshot (that caused a duplicate prompt).
        let early = core.consume(Array("%output %5 early\n".utf8))
        #expect(bytes(early).outputs.isEmpty)

        let afterCapture = core.consume(Array("%begin 3 3 0\nscreen\n%end 3 3 0\n".utf8))
        let result = bytes(afterCapture)
        #expect(result.snapshots == [Array("screen".utf8)])
        #expect(result.outputs.isEmpty) // discarded, not flushed

        // Subsequent output is emitted directly.
        let live = core.consume(Array("%output %5 more\n".utf8))
        #expect(bytes(live).outputs == [Array("more".utf8)])
    }

    @Test func outputForOtherPanesIsIgnored() {
        var core = TmuxControlModeSessionCore()
        _ = core.start(initialSize: TerminalSize(columns: 80, rows: 24))
        _ = core.consume(Array("%begin 1 1 0\n%end 1 1 0\n".utf8))
        _ = core.consume(Array("%begin 2 2 0\n1:%5\n%end 2 2 0\n".utf8))
        _ = core.consume(Array("%begin 3 3 0\nx\n%end 3 3 0\n".utf8)) // snapshot delivered

        let other = core.consume(Array("%output %9 nope\n".utf8))
        #expect(bytes(other).outputs.isEmpty)
        let mine = core.consume(Array("%output %5 yes\n".utf8))
        #expect(bytes(mine).outputs == [Array("yes".utf8)])
    }

    @Test func sendInputEncodesSendKeysForResolvedPane() {
        var core = TmuxControlModeSessionCore()
        _ = core.start(initialSize: TerminalSize(columns: 80, rows: 24))
        // No pane yet -> input is dropped.
        #expect(commands(core.sendInput([0x61])).isEmpty)

        _ = core.consume(Array("%begin 1 1 0\n%end 1 1 0\n".utf8))
        _ = core.consume(Array("%begin 2 2 0\n1:%5\n%end 2 2 0\n".utf8))

        #expect(commands(core.sendInput([0x68, 0x69])) == ["send-keys -t %5 -H 68 69"])
    }

    @Test func prefixDDetachesViaDetachClient() {
        var core = TmuxControlModeSessionCore()
        _ = core.start(initialSize: TerminalSize(columns: 80, rows: 24))
        _ = core.consume(Array("%begin 1 1 0\n%end 1 1 0\n".utf8))
        _ = core.consume(Array("%begin 2 2 0\n1:%5\n%end 2 2 0\n".utf8))
        // Ctrl-b (0x02) then 'd' (0x64) -> detach-client, no send-keys.
        #expect(commands(core.sendInput([0x02, 0x64])) == ["detach-client"])
    }

    @Test func prefixSplitAcrossCallsStillDetaches() {
        var core = TmuxControlModeSessionCore()
        _ = core.start(initialSize: TerminalSize(columns: 80, rows: 24))
        _ = core.consume(Array("%begin 1 1 0\n%end 1 1 0\n".utf8))
        _ = core.consume(Array("%begin 2 2 0\n1:%5\n%end 2 2 0\n".utf8))
        #expect(commands(core.sendInput([0x02])).isEmpty) // prefix held
        #expect(commands(core.sendInput([0x64])) == ["detach-client"])
    }

    @Test func unmappedPrefixChordPassesThrough() {
        var core = TmuxControlModeSessionCore()
        _ = core.start(initialSize: TerminalSize(columns: 80, rows: 24))
        _ = core.consume(Array("%begin 1 1 0\n%end 1 1 0\n".utf8))
        _ = core.consume(Array("%begin 2 2 0\n1:%5\n%end 2 2 0\n".utf8))
        // Ctrl-b then 'x' (not mapped) -> both bytes sent to the pane.
        #expect(commands(core.sendInput([0x02, 0x78])) == ["send-keys -t %5 -H 02 78"])
    }

    @Test func resizeEmitsRefreshClient() {
        var core = TmuxControlModeSessionCore()
        _ = core.start(initialSize: TerminalSize(columns: 80, rows: 24))
        #expect(commands(core.resize(TerminalSize(columns: 100, rows: 30))) == ["refresh-client -C 100x30"])
    }

    @Test func exitEndsSession() {
        var core = TmuxControlModeSessionCore()
        _ = core.start(initialSize: TerminalSize(columns: 80, rows: 24))
        let ended = bytes(core.consume(Array("%exit gone\n".utf8))).ended
        #expect(ended == ["gone"])
        // After end, further input produces nothing.
        #expect(core.sendInput([0x61]).isEmpty)
    }

    @Test func gatewayExitEndsSession() {
        var core = TmuxControlModeSessionCore()
        _ = core.start(initialSize: TerminalSize(columns: 80, rows: 24))
        let ended = bytes(core.gatewayExited(reason: "tmux exited (1)")).ended
        #expect(ended == ["tmux exited (1)"])
    }

    @Test func spontaneousAndEmptyBlocksAreIgnoredNotFatal() {
        // tmux emits a spontaneous entry block plus an empty refresh-client ack
        // before the list-panes response. Neither must end the session or be
        // mistaken for the pane list.
        var core = TmuxControlModeSessionCore()
        _ = core.start(initialSize: TerminalSize(columns: 80, rows: 24))
        let spontaneous = core.consume(Array("%begin 1 323 0\n%end 1 323 0\n".utf8)) // tmux entry block
        #expect(commands(spontaneous).isEmpty)
        #expect(bytes(spontaneous).ended.isEmpty)
        let refresh = core.consume(Array("%begin 2 1 0\n%end 2 1 0\n".utf8)) // refresh-client ack
        #expect(commands(refresh).isEmpty)
        #expect(bytes(refresh).ended.isEmpty)
        // The real list-panes block resolves the pane and triggers capture.
        let list = core.consume(Array("%begin 3 2 0\n1:%7\n%end 3 2 0\n".utf8))
        #expect(commands(list) == ["capture-pane -t %7 -p -e -J -S - -E -"])
    }
}
