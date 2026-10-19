import Foundation
import Testing
@testable import CmuxNextDaemon

/// A view on the daemon's own socket negotiates `terminal-binary-frames-v1`:
/// its output arrives as raw bytes and its typing goes out as input frames.
/// The view must see every byte the program printed, once and in order, NUL
/// bytes included (a NUL starts a frame on the wire), on a byte replay attach
/// and on a snapshot attach.
@Suite(.enabled(if: RealBinary.isBranchBuild, "needs the same-tree cmux-tui (scripts/cmux-next/pin-cmux-tui.sh fetch)"),
       .timeLimit(.minutes(3)), .liveDaemon)
struct BranchBinaryFramesTests {
    /// The program's payload: 2 MB of `z`, then a NUL and `done`.
    static let payloadBytes = 2_000_000

    @Test(arguments: [UInt16?.none, 1])
    func viewSeesEveryByteAndItsTypingReachesTheProgram(snapshotVersion: UInt16?) async throws {
        try await BranchDaemonHarness.with { h in
            #expect(h.identity.supports(DaemonCapabilities.shared.terminalBinaryFrames))
            let (_, _, surface) = try await h.workspaceWithTerminal("binary-frames")
            _ = try await h.run(
                #"stty -echo; printf '%s\n' "wait""ing"; read x; printf 'got-%s|' "$x"; head -c \#(Self.payloadBytes) /dev/zero | tr '\0' z; printf '\0done\n'"#,
                in: surface, until: "waiting\r\n")

            let attachment = try await TerminalAttachment.attach(
                endpoint: h.endpoint, target: .init(surface: surface, generation: h.identity.generation),
                size: CellSize(cols: 100, rows: 30), claimGeometry: true, snapshotVersion: snapshotVersion)
            let watchdog = Task {
                try await Task.sleep(for: .seconds(60))
                await attachment.detach()
            }
            defer { watchdog.cancel() }
            var events = attachment.events.makeAsyncIterator()
            switch await events.next() {
            case .replay?, .snapshot?: break
            case let other: Issue.record("attach did not start with its state: \(String(describing: other))"); return
            }
            // One input frame: the program reads the line and prints.
            attachment.enqueueInput(Data("42\r".utf8))
            var output = Data()
            var resynced = false
            var ended: TerminalChannelCloseReason?
            let end = Data("\0done\r\n".utf8)
            while let event = await events.next() {
                switch event {
                case .output(let data, _): output.append(data)
                case .snapshot(let frame) where frame.phase == .ready: resynced = true
                case .closed(let reason): ended = reason
                default: break
                }
                if output.count >= end.count, output.suffix(end.count) == end { break }
                if ended != nil { break }
            }
            attachment.detachNow()
            #expect(ended == nil, "the stream ended: \(String(describing: ended))")
            #expect(!resynced, "a fast view was never resynced")
            var expected = Data("got-42|".utf8)
            expected.append(Data(repeating: UInt8(ascii: "z"), count: Self.payloadBytes))
            expected.append(end)
            #expect(output.count == expected.count, "\(output.count) bytes, expected \(expected.count)")
            #expect(output == expected, "every byte once, in order")
        }
    }
}
