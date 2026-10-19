@testable import CmuxNextApp
import CmuxNextDaemonService
import CmuxNextLayout
import Testing

/// Lawrence 2026-10-18: "an error about moving panes" and "insanely laggy"
/// drags. NIGHTLY's log showed one `set-viewport-pane-width` per mouse move
/// (about 125 a second) during a column drag, each timing out at 2 s, and
/// then tab and pane moves timing out behind them. A gesture now keeps one
/// command in flight and sends only its newest value after it.
@MainActor @Suite struct GestureCommandCoalescerTests {
    /// A daemon that answers only when the test says so.
    @MainActor final class HeldDaemon {
        var labels: [String] = []
        private var replies: [CheckedContinuation<Bool, Never>] = []
        var waiting: Int { replies.count }

        func run(_ label: String) async -> Bool {
            labels.append(label)
            return await withCheckedContinuation { replies.append($0) }
        }

        /// Answers the oldest command, then lets the coalescer send the next one.
        func answer(_ ok: Bool = true) async {
            guard !replies.isEmpty else { return }
            replies.removeFirst().resume(returning: ok)
            for _ in 0..<20 { await Task.yield() }
        }

        func settle() async { for _ in 0..<20 { await Task.yield() } }
    }

    static let noop: DaemonCommandBody = { _ in }

    @Test func aDragOfManyMovesSendsTheFirstAndTheNewestOnly() async {
        let daemon = HeldDaemon()
        let coalescer = GestureCommandCoalescer { label, _ in await daemon.run(label) }
        let gesture = LayoutTransactionID.make()
        var outcomes: [(Bool, Bool)] = []
        for move in 0..<125 {
            coalescer.submit(gesture, phase: .changed, label: "width-\(move)", Self.noop) { outcomes.append(($0, $1)) }
        }
        await daemon.settle()
        #expect(daemon.labels == ["width-0"])
        await daemon.answer()
        #expect(daemon.labels == ["width-0", "width-124"])
        await daemon.answer()
        #expect(coalescer.sent == 2)
        #expect(!coalescer.isBusy(gesture))
        #expect(outcomes.count == 2)
    }

    @Test func theEndedValueGoesLastAndIsNeverReplaced() async {
        let daemon = HeldDaemon()
        let coalescer = GestureCommandCoalescer { label, _ in await daemon.run(label) }
        let gesture = LayoutTransactionID.make()
        var ended: Bool?
        coalescer.submit(gesture, phase: .changed, label: "live", Self.noop) { _, _ in }
        coalescer.submit(gesture, phase: .changed, label: "live-2", Self.noop) { _, _ in }
        coalescer.submit(gesture, phase: .ended, label: "end", Self.noop) { ok, _ in ended = ok }
        coalescer.submit(gesture, phase: .changed, label: "late", Self.noop) { _, _ in }
        await daemon.settle()
        await daemon.answer()
        #expect(daemon.labels == ["live", "end"])
        await daemon.answer(true)
        #expect(ended == true)
    }

    @Test func aFailedLiveValueWithANewerOneWaitingIsSuperseded() async {
        let daemon = HeldDaemon()
        let coalescer = GestureCommandCoalescer { label, _ in await daemon.run(label) }
        let gesture = LayoutTransactionID.make()
        var first: (ok: Bool, superseded: Bool)?
        coalescer.submit(gesture, phase: .changed, label: "a", Self.noop) { first = ($0, $1) }
        coalescer.submit(gesture, phase: .changed, label: "b", Self.noop) { _, _ in }
        await daemon.settle()
        await daemon.answer(false)
        #expect(first?.ok == false)
        #expect(first?.superseded == true)
    }

    @Test func gesturesDoNotWaitForEachOther() async {
        let daemon = HeldDaemon()
        let coalescer = GestureCommandCoalescer { label, _ in await daemon.run(label) }
        coalescer.submit(.make(), phase: .changed, label: "split", Self.noop) { _, _ in }
        coalescer.submit(.make(), phase: .changed, label: "column", Self.noop) { _, _ in }
        await daemon.settle()
        #expect(daemon.labels.sorted() == ["column", "split"])
        await daemon.answer()
        await daemon.answer()
    }
}
