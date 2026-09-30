import CmuxNextBridge
import CmuxNextDaemon
import Foundation
import Testing

/// A daemon `resized` must resize the live Ghostty mirror in place. It must
/// never become a replay, because a replay makes the view swap in a fresh
/// surface.
@Suite struct TerminalStreamPlanTests {
    let replay = TerminalReplay(cols: 120, rows: 40, data: Data("\u{1B}cprompt$ ".utf8))

    @Test func resizedResizesAndNeverReplays() {
        #expect(TerminalStreamPlan.steps(for: .resized(replay)) == [.grid(columns: 120, rows: 40)])
    }

    @Test func initialReplaySizesTheGridFirst() {
        #expect(TerminalStreamPlan.steps(for: .replay(replay)) == [.grid(columns: 120, rows: 40), .replay(replay)])
    }

    /// A replay taken inside an escape sequence: the unfinished bytes follow
    /// it, so the next live chunk completes the sequence in the mirror.
    @Test func pendingSequenceFollowsTheInitialReplay() {
        var inside = replay
        inside.pending = Data("\u{1B}[1;3".utf8)
        #expect(TerminalStreamPlan.steps(for: .replay(inside))
            == [.grid(columns: 120, rows: 40), .replay(inside), .output(Data("\u{1B}[1;3".utf8))])
        // The mirror parsed those bytes from the live stream already.
        #expect(TerminalStreamPlan.steps(for: .resized(inside)) == [.grid(columns: 120, rows: 40)])
    }

    @Test func outputAndLifecycle() {
        let bytes = Data("ls\r\n".utf8)
        #expect(TerminalStreamPlan.steps(for: .output(bytes, colors: nil)) == [.output(bytes)])
        #expect(TerminalStreamPlan.steps(for: .closed(.surfaceGone)) == [.exited])
        #expect(TerminalStreamPlan.steps(for: .closed(.overflow)).isEmpty)
        #expect(TerminalStreamPlan.steps(for: .scrollChanged(offset: 3, atBottom: false)).isEmpty)
    }
}
