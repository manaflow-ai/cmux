#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
@testable import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// The S7 live-resize probe's commit witness (`liveResize.commit_inside`): in a window's layer tree, as the probe uses
/// it, it must say "committed" after a Core Animation commit and "not committed" before one, or the films' answer to
/// "does AppKit commit inside a live-resize setFrame?" means nothing. (A layer outside any window never shows a commit
/// in its presentation copy: the probe attaches the witness to the window's content view.)
@MainActor
@Suite(.serialized, .closesItsWindows)
struct CommitWitnessTests {
    @Test func inAWindowItSeesACommitAndOnlyACommit() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 120), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 120))
        content.wantsLayer = true
        window.contentView = content
        window.orderFrontRegardless()
        let root = try #require(content.layer, "the content view has no layer")
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
