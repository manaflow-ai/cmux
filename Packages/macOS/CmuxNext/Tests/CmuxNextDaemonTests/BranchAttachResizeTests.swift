import Foundation
import Testing
@testable import CmuxNextDaemon

/// A view's attach stream must survive a PTY resize while the program is in
/// the middle of an escape sequence (dogfood nxdog11: "after killing and
/// reopening, persisted sessions are kinda frozen"). A relaunch attaches
/// every restored surface at a provisional grid and claims the pane's real
/// grid right after the replay, so each busy terminal resizes mid-stream.
@Suite(.enabled(if: RealBinary.isBranchBuild, "needs the same-tree cmux-tui (scripts/cmux-next/pin-cmux-tui.sh fetch)"),
       .timeLimit(.minutes(2)), .liveDaemon)
struct BranchAttachResizeTests {
    @Test func outputContinuesAfterAResizeInsideAnEscapeSequence() async throws {
        try await BranchDaemonHarness.with { h in
            let (_, _, surface) = try await h.workspaceWithTerminal("mid-sequence")
            // The program leaves the parser inside `CSI 1;3` and waits for a line.
            _ = try await h.run(
                #"stty -echo; printf '%s\n\033[1;3' "wait""ing"; read x; printf 'm after-%s\n' "$x""#,
                in: surface, until: "waiting\r\n")

            let attachment = try await TerminalAttachment.attach(
                endpoint: h.endpoint, target: .init(surface: surface, generation: h.identity.generation),
                size: CellSize(cols: 100, rows: 30), claimGeometry: true)
            let watchdog = Task {
                try await Task.sleep(for: .seconds(15))
                await attachment.detach()
            }
            defer { watchdog.cancel() }
            var events = attachment.events.makeAsyncIterator()
            guard case .replay? = await events.next() else {
                Issue.record("attach did not start with a replay")
                return
            }
            // The view settles on another grid: the daemon resizes the PTY
            // while its parser is inside the sequence.
            attachment.claimGeometry(reporting: CellSize(cols: 90, rows: 28))
            var resized = false
            var output = ""
            var ended: TerminalChannelCloseReason?
            while let event = await events.next() {
                switch event {
                case .resized(let replay):
                    resized = replay.cols == 90
                    if resized { attachment.enqueueInput(Data("42\r".utf8)) }
                case .output(let data, _):
                    output += String(decoding: data, as: UTF8.self)
                case .closed(let reason):
                    ended = reason
                default:
                    break
                }
                if output.contains("after-42") || ended != nil { break }
            }
            attachment.detachNow()
            #expect(resized, "the claim did not resize the PTY")
            #expect(ended == nil, "the attach stream ended after the resize: \(String(describing: ended))")
            #expect(output.contains("after-42"), "no output reached the view after the resize: \(output.debugDescription)")
        }
    }
}
