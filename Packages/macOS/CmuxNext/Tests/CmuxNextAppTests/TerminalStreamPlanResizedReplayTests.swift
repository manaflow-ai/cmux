import CmuxNextBridge
import CmuxNextDaemon
import Foundation
import Testing

/// manaflow-ai/cmux#12381: in the replay fallback (no GHOSTSNP), a daemon `resized` event
/// carries the screen already reflowed at the new width. The Ghostty mirror never reflows on
/// its own resize, so the plan must rebuild the mirror from that replay. When it drops the
/// replay, a pane that narrows (246 -> 121 columns) keeps its old wide rows clipped with their
/// wrap flags, and new output paints over them.
struct TerminalStreamPlanResizedReplayTests {
    @Test func aResizedReplayRebuildsTheMirrorAtTheNewGrid() {
        let replay = TerminalReplay(cols: 121, rows: 40, data: Data("reflowed at 121\r\n$ ".utf8))
        let steps = TerminalStreamPlan.steps(for: .resized(replay))
        #expect(steps.first == .grid(columns: 121, rows: 40))
        #expect(steps.contains(.replay(replay)))
        #expect(steps == TerminalStreamPlan.steps(for: .replay(replay)))
    }

    @Test func aResizedReplayKeepsItsUnfinishedSequenceAfterTheReplay() throws {
        let pending = Data("\u{1B}[3".utf8)
        let replay = TerminalReplay(cols: 121, rows: 40, data: Data("$ ".utf8), pending: pending)
        let steps = TerminalStreamPlan.steps(for: .resized(replay))
        let replayIndex = try #require(steps.firstIndex(of: .replay(replay)))
        let outputIndex = try #require(steps.firstIndex { step in
            if case .output(let bytes) = step { return bytes.hasSuffix(pending) }
            return false
        })
        #expect(outputIndex > replayIndex)
    }
}

private extension Data {
    func hasSuffix(_ suffix: Data) -> Bool { count >= suffix.count && self.suffix(suffix.count) == suffix }
}
