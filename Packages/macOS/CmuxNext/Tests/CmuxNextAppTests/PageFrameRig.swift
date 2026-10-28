@testable import CmuxNextWakeups
import Foundation

/// The app's main-thread scheduler on a display link the test fires, with an uptime the test moves
/// and an input source it sets (the p06-scheduler harness for App owners): a posted task or an
/// observation's flush waits for ``frame()``, and budgeted work yields while ``inputPending``.
@MainActor
final class PageFrameRig {
    let work: MainWorkScheduler
    private let input: PageRigInput
    private let uptime: PageRigUptime
    /// Keeps the display link up, so a post waits for the test's frames, not a run loop turn.
    private let keeper: FrameClient
    private var timestamp: Double = 0

    init() {
        let input = PageRigInput(), uptime = PageRigUptime()
        self.input = input
        self.uptime = uptime
        work = MainWorkScheduler.testing(budget: MainFrameBudget(input: input, uptimeNanos: uptime.read), ledger: WakeupLedger()) { _ in
            PageRigLink()
        }
        keeper = FrameClient(owner: "test.keeper", isAnimation: false, on: work.frames) { _ in true }
        keeper.activate()
    }

    /// Whether the person's next input is pending: the budgeted classes yield to it.
    var inputPending: Bool {
        get { input.pending }
        set { input.pending = newValue }
    }

    /// One display frame, a frame period after the last.
    func frame() {
        uptime.now += 17_000_000
        timestamp += 1
        work.frameDidFire(timestamp: timestamp, refreshInterval: 1.0 / 60)
    }
}

@MainActor
private final class PageRigInput: InputPendingSource {
    var pending = false
    func hasPendingInput(uptime: TimeInterval) -> Bool { pending }
}

@MainActor
private final class PageRigUptime {
    var now: UInt64 = 1_000_000_000
    // Strong: the scheduler may read it after the test returned.
    var read: () -> UInt64 { { [self] in self.now } }
}

private final class PageRigLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}
