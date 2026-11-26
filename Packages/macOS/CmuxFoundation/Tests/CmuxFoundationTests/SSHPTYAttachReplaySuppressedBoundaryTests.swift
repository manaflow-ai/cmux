import Foundation
import Testing
@testable import CmuxFoundation

/// A managed reconnect drops the replay prefix an earlier attempt already
/// rendered before the query filter sees it. The filter's replay boundary
/// must move past those dropped bytes, or it keeps a replay budget for bytes
/// it never receives and strips queries from live output after the replay.
@Suite("SSH PTY attach replay boundary after suppressed bytes")
struct SSHPTYAttachReplaySuppressedBoundaryTests {
    private static let primaryDA = "\u{1B}[c"

    private func text(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self)
    }

    @Test("a validated duplicate prefix does not keep live queries inside the replay budget")
    func validatedPrefixAdvancesQueryBoundary() {
        let prefix = Data("old prompt$ ".utf8)
        let suffix = Data("new line\n".utf8)
        let replayBytes = prefix.count + suffix.count
        var output = SSHPTYAttachReplayOutputStream(
            progress: SSHPTYAttachOutputProgress(
                replayBytes: replayBytes,
                suppressReplayBytes: prefix.count,
                expectedReplayFingerprint: SSHPTYAttachOutputProgress.fingerprint(of: prefix)
            ),
            queryFilterReplayBytes: replayBytes
        )

        let replay = output.terminalOutput(from: prefix + suffix, suppressingReplay: true)
        #expect(text(replay) == text(suffix))
        #expect(output.progress.replayBytesRemaining == 0)

        // The declared replay is over; a query now is live and must reach the
        // terminal so it can answer the running program.
        let live = output.terminalOutput(from: Data(Self.primaryDA.utf8), suppressingReplay: true)
        #expect(text(live) == Self.primaryDA)
    }

    @Test("a legacy suppressed prefix does not keep live queries inside the replay budget")
    func unvalidatedSuppressionAdvancesQueryBoundary() {
        let prefix = Data("old prompt$ ".utf8)
        var output = SSHPTYAttachReplayOutputStream(
            progress: SSHPTYAttachOutputProgress(replayBytes: prefix.count),
            queryFilterReplayBytes: prefix.count
        )

        #expect(output.terminalOutput(from: prefix, suppressingReplay: true).isEmpty)

        let live = output.terminalOutput(from: Data(Self.primaryDA.utf8), suppressingReplay: true)
        #expect(text(live) == Self.primaryDA)
    }

    @Test("a prefix that fails validation keeps the full replay budget")
    func failedValidationKeepsFullBudget() {
        let rendered = Data("old prompt$ ".utf8)
        let replaced = Data("new prompt\(Self.primaryDA)".utf8)
        var output = SSHPTYAttachReplayOutputStream(
            progress: SSHPTYAttachOutputProgress(
                replayBytes: replaced.count,
                suppressReplayBytes: rendered.count,
                expectedReplayFingerprint: SSHPTYAttachOutputProgress.fingerprint(of: rendered)
            ),
            queryFilterReplayBytes: replaced.count
        )

        // The snapshot rolled over, so the whole replay is forwarded and its
        // historical query is still stripped.
        let replay = output.terminalOutput(from: replaced, suppressingReplay: true)
        #expect(text(replay) == "new prompt")
    }
}
