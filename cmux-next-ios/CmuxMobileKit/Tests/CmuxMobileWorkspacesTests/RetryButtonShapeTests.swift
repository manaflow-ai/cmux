#if os(iOS)
import CmuxMobileDesign
import SwiftUI
import Testing
import UIKit

/// The shared Retry is a capsule: wider than tall at every text size, so a
/// short title never draws as a circle (a 44 pt label height inside a glass
/// button made "Retry" about 60 x 58 pt, a circle in loading pages).
@MainActor @Suite struct RetryButtonShapeTests {
    nonisolated static let sizes: [DynamicTypeSize] = [.small, .large, .xxxLarge, .accessibility3]

    private func size(_ view: some View, _ type: DynamicTypeSize) -> CGSize {
        let host = UIHostingController(rootView: view.dynamicTypeSize(type))
        return host.sizeThatFits(in: CGSize(width: 400, height: 400))
    }

    @Test(arguments: sizes) func retryIsACapsuleNotACircle(type: DynamicTypeSize) {
        let fitted = size(RetryButton {}, type)
        #expect(fitted.height > 0)
        // A capsule: clearly wider than tall (a circle is 1:1).
        #expect(fitted.width >= fitted.height * 1.5, "Retry is \(fitted.width) x \(fitted.height) pt")
    }

    @Test func retryKeepsTheInlineCapsuleHeight() {
        // SPEC 4.1 inline capsule: 40 pt drawn in a 44 pt target, never taller.
        let fitted = size(RetryButton {}, .large)
        #expect(fitted.height <= 44, "Retry is \(fitted.height) pt tall")
    }

    @Test func retryGrowsWithAccessibilityTextInsteadOfClipping() {
        // Its title at AX3 is taller than 40 pt; the capsule holds it.
        let large = size(RetryButton {}, .large)
        let ax = size(RetryButton {}, .accessibility3)
        #expect(ax.height > large.height, "Retry is \(ax.height) pt tall at AX3")
    }
}

/// Retry's spinner holds briefly once shown, so an answer in a frame or two reads
/// as a load instead of a flicker, and a cancelled retry lets go at once.
@MainActor @Suite struct RetryButtonHoldTests {
    @Test func aFastAnswerStillShowsTheSpinnerForTheMinimum() async {
        let clock = ContinuousClock()
        let start = clock.now
        var ran = false
        await RetryButton.run({ ran = true }, holdingFor: .milliseconds(120), on: clock)
        #expect(ran)
        #expect(clock.now - start >= .milliseconds(120))
    }

    @Test func aSlowAnswerIsNotHeldLonger() async {
        // A recorded clock, not wall time: a loaded simulator once measured a
        // 150 ms answer at 1.24 s. The answer takes 150 ms on this clock; the
        // hold (50 ms) then asks to sleep until a time already past, so it adds nothing.
        let clock = RecordedClock()
        await RetryButton.run({ clock.advance(by: .milliseconds(150)) }, holdingFor: .milliseconds(50), on: clock)
        #expect(clock.sleptUntil.count == 1)
        #expect(clock.sleptUntil.allSatisfy { $0 <= clock.now })
        #expect(clock.now == RecordedClock.Instant(offset: .milliseconds(150)))
    }

    @Test func aCancelledRetryEndsWithoutTheHold() async {
        let clock = ContinuousClock()
        let start = clock.now
        let task = Task { @MainActor in
            await RetryButton.run({ withUnsafeCurrentTask { $0?.cancel() } }, holdingFor: .seconds(30), on: clock)
        }
        await task.value
        #expect(clock.now - start < .seconds(5))
    }
}

/// A clock that only moves when told to, and records each sleep's deadline
/// (a sleep ends at once and moves the clock to its deadline when that is later).
final class RecordedClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private let lock = NSLock()
    private var current = Instant(offset: .zero)
    private var deadlines: [Instant] = []

    var now: Instant { lock.withLock { current } }
    var minimumResolution: Duration { .zero }
    var sleptUntil: [Instant] { lock.withLock { deadlines } }

    func advance(by duration: Duration) { lock.withLock { current = current.advanced(by: duration) } }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        try Task.checkCancellation()
        lock.withLock {
            deadlines.append(deadline)
            if current < deadline { current = deadline }
        }
    }
}
#endif
