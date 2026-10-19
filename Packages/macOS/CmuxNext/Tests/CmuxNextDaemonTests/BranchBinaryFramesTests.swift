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
    /// The program prints `seq 1 300000` (about 2 MB of distinct lines, so a
    /// lost or repeated chunk breaks the comparison), then a NUL and `done`.
    static let lines = 300_000

    @Test(arguments: [UInt16?.none, 1])
    func viewSeesEveryByteAndItsTypingReachesTheProgram(snapshotVersion: UInt16?) async throws {
        try await BranchDaemonHarness.with { h in
            #expect(h.identity.supports(DaemonCapabilities.shared.terminalBinaryFrames))
            let (_, _, surface) = try await h.workspaceWithTerminal("binary-frames")
            // `exec sleep`: no prompt follows the payload.
            _ = try await h.run(
                #"stty -echo; printf '%s\n' "wait""ing"; read x; printf 'got-%s|' "$x"; seq 1 300000; printf '\0done\n'; exec sleep 600"#,
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
            var ended: TerminalChannelCloseReason?
            let end = Data("\0done\r\n".utf8)
            while let event = await events.next() {
                switch event {
                case .output(let data, _): output.append(data)
                // A READY or a replay (the claim's grid change) holds every
                // byte before its cut; the output after it continues there.
                case .snapshot(let frame) where frame.phase == .ready: output.removeAll()
                case .resized: output.removeAll()
                case .closed(let reason): ended = reason
                default: break
                }
                if output.range(of: end) != nil || ended != nil { break }
            }
            attachment.detachNow()
            #expect(ended == nil, "the stream ended: \(String(describing: ended))")
            var expected = Data("got-42|".utf8)
            expected.append(Data((1...Self.lines).map { "\($0)\r\n" }.joined().utf8))
            expected.append(end)
            #expect(output.count > 1_000_000, "the output after the last grid change: \(output.count) bytes")
            #expect(output.count <= expected.count && expected.suffix(output.count) == output,
                    "every byte once, in order: \(output.count) bytes, expected a suffix of \(expected.count)")
            if snapshotVersion == nil {
                #expect(output.starts(with: Data("got-42|".utf8)), "the typed line reached the program")
            }
        }
    }
}
