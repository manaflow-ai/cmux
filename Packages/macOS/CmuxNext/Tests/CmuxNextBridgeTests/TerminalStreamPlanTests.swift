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

    @Test func outputAndLifecycle() {
        let bytes = Data("ls\r\n".utf8)
        #expect(TerminalStreamPlan.steps(for: .output(bytes, colors: nil)) == [.output(bytes)])
        #expect(TerminalStreamPlan.steps(for: .closed(.surfaceGone)) == [.exited])
        #expect(TerminalStreamPlan.steps(for: .closed(.overflow)).isEmpty)
        #expect(TerminalStreamPlan.steps(for: .scrollChanged(offset: 3, atBottom: false)).isEmpty)
    }
}
