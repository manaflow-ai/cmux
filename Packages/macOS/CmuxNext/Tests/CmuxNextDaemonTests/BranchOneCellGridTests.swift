import Foundation
import Testing
@testable import CmuxNextDaemon

/// A pane one terminal cell big (handoff pane-min.md, repeat-runoff.md part 2): its view claims a 1 x 1 grid, the
/// daemon gives the PTY exactly that, the shell in it keeps running and answering, and a larger grid later reaches
/// the PTY again.
@Suite(.enabled(if: RealBinary.isBranchBuild, "needs the same-tree cmux-tui (scripts/cmux-next/pin-cmux-tui.sh fetch)"),
       .timeLimit(.minutes(2)), .liveDaemon)
struct BranchOneCellGridTests {
    @Test func aOneByOneGridKeepsTheShellRunningAndGrowsBack() async throws {
        try await BranchDaemonHarness.with { h in
            let (_, _, surface) = try await h.workspaceWithTerminal("one-cell")
            _ = try await h.run("stty -echo; echo ready-one-cell", in: surface, until: "ready-one-cell\r\n")
            let attachment = try await TerminalAttachment.attach(
                endpoint: h.endpoint, target: .init(surface: surface, generation: h.identity.generation),
                size: CellSize(cols: 1, rows: 1), claimGeometry: true)
            let watchdog = Task {
                try await Task.sleep(for: .seconds(30))
                await attachment.detach()
            }
            defer { watchdog.cancel() }
            var events = attachment.events.makeAsyncIterator()
            guard case .replay? = await events.next() else {
                Issue.record("attach did not start with a replay")
                return
            }
            // The view's grid is one cell; the size is asked again once the PTY has it.
            let ask = Data(#"printf 'size=%s:\n' "$(stty size)"\#r"#.utf8)
            attachment.claimGeometry(reporting: CellSize(cols: 1, rows: 1))
            attachment.enqueueInput(ask)
            var output = ""
            var resizedBack = false
            var ended: TerminalChannelCloseReason?
            while let event = await events.next() {
                switch event {
                case .output(let data, _):
                    output += String(decoding: data, as: UTF8.self)
                    if output.contains("size=1 1:"), !resizedBack {
                        resizedBack = true
                        attachment.claimGeometry(reporting: CellSize(cols: 80, rows: 24))
                    }
                case .resized(let replay) where replay.cols == 1 || replay.cols == 80:
                    attachment.enqueueInput(ask)
                case .closed(let reason):
                    ended = reason
                default:
                    break
                }
                if output.contains("size=24 80:") || ended != nil { break }
            }
            attachment.detachNow()
            #expect(ended == nil, "the terminal closed at 1 x 1: \(String(describing: ended))")
            #expect(output.contains("size=1 1:"), "the PTY did not get 1 x 1: \(output.debugDescription)")
            #expect(output.contains("size=24 80:"), "the PTY did not grow back to 80 x 24: \(output.debugDescription)")
        }
    }
}
