import Foundation
import Testing
@testable import CmuxFoundation

/// A remote daemon declares its replay length. These tests cover a peer that
/// declares more than it sends and a reconnect replay larger than the
/// validation buffer: input must resume and no output may be lost.
@Suite("SSH PTY attach replay bounds")
struct SSHPTYAttachReplayBoundTests {
    private func text(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self)
    }

    @Test("a replay that goes quiet before its declared length expires at the idle deadline")
    func stalledReplayExpiresAtIdleDeadline() {
        var deadline = SSHPTYAttachReplayDeadline(startedAt: 100, idleTimeout: 2, totalTimeout: 10)
        #expect(deadline.remainingWait(at: 100) == 2)

        deadline.recordOutput(at: 101)
        #expect(deadline.remainingWait(at: 102) == 1)
        #expect(deadline.remainingWait(at: 103) == 0)
        #expect(deadline.remainingWait(at: 104) == 0)
    }

    @Test("a replay that keeps trickling still ends at the total deadline")
    func tricklingReplayEndsAtTotalDeadline() {
        var deadline = SSHPTYAttachReplayDeadline(startedAt: 0, idleTimeout: 2, totalTimeout: 10)
        for second in 0..<9 {
            deadline.recordOutput(at: TimeInterval(second))
        }

        #expect(deadline.remainingWait(at: 8.5) == 1.5)
        #expect(deadline.remainingWait(at: 9.5) == 0.5)
        #expect(deadline.remainingWait(at: 10) == 0)
    }

    @Test("ending a stalled replay lets later bytes count as live output")
    func endingStalledReplayResumesLiveOutput() {
        var progress = SSHPTYAttachOutputProgress(replayBytes: 1_000)
        let replay = progress.terminalOutput(from: Data("partial".utf8), suppressingReplay: false)
        #expect(text(replay) == "partial")
        #expect(progress.replayBytesRemaining == 993)

        let pending = progress.endReplay()

        #expect(pending.isEmpty)
        #expect(progress.replayBytesRemaining == 0)
        #expect(progress.deliveredReplayBytes == 7)
        #expect(
            progress.completedReplayFingerprint ==
                SSHPTYAttachOutputProgress.fingerprint(of: Data("partial".utf8))
        )
        let live = progress.terminalOutput(from: Data("typed".utf8), suppressingReplay: false)
        #expect(text(live) == "typed")
        #expect(progress.receivedLiveOutput)
    }

    @Test("ending a stalled reconnect replay forwards the buffered output")
    func endingStalledReconnectReplayFlushesBuffer() {
        var progress = SSHPTYAttachOutputProgress(
            replayBytes: 100,
            suppressReplayBytes: 6,
            expectedReplayFingerprint: SSHPTYAttachOutputProgress.fingerprint(
                of: Data("oldold".utf8)
            )
        )
        let buffered = progress.terminalOutput(from: Data("oldoldnew".utf8), suppressingReplay: true)
        #expect(buffered.isEmpty)

        let pending = progress.endReplay()

        #expect(text(pending) == "new")
        #expect(progress.replayBytesRemaining == 0)
        #expect(progress.deliveredReplayBytes == 9)
        let live = progress.terminalOutput(from: Data("typed".utf8), suppressingReplay: true)
        #expect(text(live) == "typed")
    }

    @Test("a stalled reconnect replay drops a partial prefix candidate when a retry is pending")
    func endingStalledReconnectReplayDiscardsPartialCandidate() {
        func progress() -> SSHPTYAttachOutputProgress {
            SSHPTYAttachOutputProgress(
                replayBytes: 100,
                suppressReplayBytes: 6,
                expectedReplayFingerprint: SSHPTYAttachOutputProgress.fingerprint(
                    of: Data("oldold".utf8)
                )
            )
        }
        // The previous attempt already rendered "oldold"; this attempt
        // received only part of that prefix before the replay deadline.
        var retrying = progress()
        #expect(retrying.terminalOutput(from: Data("old".utf8), suppressingReplay: true).isEmpty)

        #expect(retrying.endReplay(discarding: true).isEmpty)
        #expect(retrying.replayBytesRemaining == 0)
        #expect(retrying.finishPendingReplay(discarding: true).isEmpty)
        #expect(text(retrying.terminalOutput(from: Data("typed".utf8), suppressingReplay: true)) == "typed")

        // Without another attempt, nothing else will render the candidate.
        var lastAttempt = progress()
        #expect(lastAttempt.terminalOutput(from: Data("old".utf8), suppressingReplay: true).isEmpty)
        #expect(text(lastAttempt.endReplay(discarding: false)) == "old")
    }

    @Test("a stalled reconnect replay still forwards validated output when a retry is pending")
    func endingStalledReconnectReplayKeepsValidatedOutput() {
        var progress = SSHPTYAttachOutputProgress(
            replayBytes: 100,
            suppressReplayBytes: 6,
            expectedReplayFingerprint: SSHPTYAttachOutputProgress.fingerprint(
                of: Data("oldold".utf8)
            )
        )
        #expect(progress.terminalOutput(from: Data("oldoldnew".utf8), suppressingReplay: true).isEmpty)

        // "new" follows a proven duplicate prefix and the replay state stored
        // after the deadline covers it, so no later attempt would render it.
        #expect(text(progress.endReplay(discarding: true)) == "new")
    }

    @Test("the output stream passes the retry decision to a stalled replay")
    func stalledReplayStreamDiscardsPartialCandidate() {
        var output = SSHPTYAttachReplayOutputStream(
            progress: SSHPTYAttachOutputProgress(
                replayBytes: 100,
                suppressReplayBytes: 6,
                expectedReplayFingerprint: SSHPTYAttachOutputProgress.fingerprint(
                    of: Data("oldold".utf8)
                )
            ),
            queryFilterReplayBytes: 100
        )
        #expect(output.terminalOutput(from: Data("old".utf8), suppressingReplay: true).isEmpty)

        #expect(output.endStalledReplay(discardingPendingReplay: true).isEmpty)
        #expect(output.finish(discardingPendingReplay: true).isEmpty)
    }

    @Test("a reconnect replay larger than the validation buffer is forwarded, not dropped")
    func oversizedValidatedReplayIsForwarded() {
        let prefix = Data(repeating: 0x61, count: 6)
        let appended = Data(repeating: 0x62, count: (1 << 20) + 100_000)
        let tail = Data("tail!".utf8)
        let live = Data("live".utf8)
        var progress = SSHPTYAttachOutputProgress(
            replayBytes: prefix.count + appended.count + tail.count,
            suppressReplayBytes: prefix.count,
            expectedReplayFingerprint: SSHPTYAttachOutputProgress.fingerprint(of: prefix)
        )

        let stream = prefix + appended + tail + live
        var output = Data()
        var offset = 0
        while offset < stream.count {
            let end = min(offset + 32_768, stream.count)
            output.append(progress.terminalOutput(
                from: Data(stream[offset..<end]),
                suppressingReplay: true
            ))
            offset = end
        }
        output.append(progress.finishPendingReplay())

        // Compare through Bools so a failure does not diff megabytes of Data.
        let expected = appended + tail + live
        let forwardedByteCount = output.count
        let forwardedEveryByteInOrder = output == expected
        #expect(forwardedByteCount == expected.count)
        #expect(forwardedEveryByteInOrder)
        #expect(progress.replayBytesRemaining == 0)
    }
}
