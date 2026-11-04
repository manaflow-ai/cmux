#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
@testable import CmuxNextDesign
import Testing

/// The S7 live-resize probe's commit witness (`liveResize.commit_inside`): it must say "committed" after a Core
/// Animation commit and "not committed" before one, or the films' answer to "does AppKit commit inside a live-resize
/// setFrame?" means nothing.
@MainActor
@Suite(.serialized)
struct CommitWitnessTests {
    @Test func itSeesACommitAndOnlyACommit() {
        let root = CALayer()
        let witness = CommitWitness()
        witness.attach(to: root)
        CATransaction.flush()
        witness.arm()
        #expect(!witness.committed, "the witness saw a commit that did not happen")
        CATransaction.flush()
        #expect(witness.committed, "the witness missed a commit")
        witness.arm()
        #expect(!witness.committed, "a second arm still reads the first commit")
        CATransaction.flush()
        #expect(witness.committed, "the witness missed the second commit")
    }
}
#endif
