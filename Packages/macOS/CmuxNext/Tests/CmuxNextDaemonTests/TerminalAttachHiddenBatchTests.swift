import Foundation
import Testing
@testable import CmuxNextDaemon

/// SWITCH FRAMES SF-5 C (busy gate on a 2x display, 2026-11-02): with 8 warm hidden terminals printing 20 lines/s the
/// app woke about 115 times a second, because each hidden terminal's attach stream sent every output frame at once.
/// A view that hides tells a daemon with `attach-visibility-v1` so it batches that view's output to once a second, and
/// tells it again when it shows, whatever its sizing state; a daemon without it gets only the sizing commands.
struct TerminalAttachHiddenBatchTests {
    @Test func aHiddenViewAsksTheDaemonToBatchItsOutputAndShowingEndsIt() {
        let hide = TerminalAttachment.hiddenSteps(hidden: true, lease: "l1", inPlace: true, batchesHidden: true)
        #expect(hide == [.sizeCounts(lease: "l1", counts: false), .visibility(false)], "\(hide)")
        let show = TerminalAttachment.hiddenSteps(hidden: false, lease: "l1", inPlace: true, batchesHidden: true)
        #expect(show == [.visibility(true), .sizeCounts(lease: "l1", counts: nil)], "\(show)")
        // A daemon that replied with no lease: the batching still follows the view.
        #expect(TerminalAttachment.hiddenSteps(hidden: true, lease: nil, inPlace: true, batchesHidden: true) == [.visibility(false)])
        // An older daemon: sizing only, as before.
        #expect(TerminalAttachment.hiddenSteps(hidden: true, lease: "l1", inPlace: false, batchesHidden: false) == [.releaseSize(lease: "l1")])
        #expect(TerminalAttachment.hiddenSteps(hidden: false, lease: "l1", inPlace: false, batchesHidden: false) == [.claim])
    }
}
