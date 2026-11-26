import Foundation
import Testing
@testable import CmuxFoundation

/// The replay deadline only stops holding keystrokes. Queries in replay bytes
/// that arrive after it fires are still historical and must not reach the
/// local terminal, or its replies are typed into the now-live remote shell.
@Suite("SSH PTY attach replay output stream")
struct SSHPTYAttachReplayOutputStreamTests {
    private static let osc52Read = "\u{1B}]52;c;?\u{07}"
    private static let primaryDA = "\u{1B}[c"

    private func text(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self)
    }

    private func stream(replayBytes: Int) -> SSHPTYAttachReplayOutputStream {
        SSHPTYAttachReplayOutputStream(
            progress: SSHPTYAttachOutputProgress(replayBytes: replayBytes),
            queryFilterReplayBytes: replayBytes
        )
    }

    @Test("replay bytes after a stalled-replay deadline still have their queries stripped")
    func replayAfterDeadlineKeepsQueryFilter() {
        let head = "old prompt$ "
        let tail = "a\(Self.osc52Read)b\(Self.primaryDA)c"
        var output = stream(replayBytes: head.utf8.count + tail.utf8.count)

        #expect(text(output.terminalOutput(from: Data(head.utf8), suppressingReplay: false)) == head)
        #expect(output.progress.replayBytesRemaining > 0)

        // The link stalls past the deadline: input forwarding may start.
        #expect(output.endStalledReplay().isEmpty)
        #expect(output.progress.replayBytesRemaining == 0)

        // The rest of the declared replay then arrives.
        let late = output.terminalOutput(from: Data(tail.utf8), suppressingReplay: false)
        #expect(text(late) == "abc")

        // Output past the declared replay is live and keeps its queries.
        let live = output.terminalOutput(from: Data(Self.primaryDA.utf8), suppressingReplay: false)
        #expect(text(live) == Self.primaryDA)
    }

    @Test("a query split across the deadline and the next replay chunk is stripped")
    func splitQueryAcrossDeadlineIsStripped() {
        var output = stream(replayBytes: 64)
        #expect(text(output.terminalOutput(from: Data("x\u{1B}]52;c".utf8), suppressingReplay: false)) == "x")

        #expect(output.endStalledReplay().isEmpty)

        #expect(text(output.terminalOutput(from: Data(";?\u{07}y".utf8), suppressingReplay: false)) == "y")
    }

    @Test("a declared replay beyond the daemon's scrollback cap stops filtering at the cap")
    func oversizedDeclaredReplayIsCapped() {
        let cap = 1 << 20
        var output = stream(replayBytes: Int.max)
        let filler = Data(repeating: 0x61, count: cap)
        let forwarded = output.terminalOutput(from: filler, suppressingReplay: false)
        #expect(forwarded.count == cap)

        // A peer cannot make every later query look historical.
        let live = output.terminalOutput(from: Data(Self.primaryDA.utf8), suppressingReplay: false)
        #expect(text(live) == Self.primaryDA)
    }
}
