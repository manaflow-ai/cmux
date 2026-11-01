import AppKit
import QuartzCore
@testable import CmuxNextLayout

/// Who owns a main-thread gap in an animation pixel run. These tests host the real layout views in
/// the test process, so "the app" is the layout's own frame work there: every display-link step of
/// the layout (`LayoutRootView.driver.onFrame`, wrapped here) and every window resize the test makes
/// (its layout and display happen inside `setFrame`). Everything else on the main thread is the
/// harness (capture reads, the samplers) or AppKit.
///
/// A run-loop observer records each main run-loop turn (from waking to waiting). For a missed
/// display refresh, ``owner(from:to:)`` names the longest turn in the gap and how much of it was
/// layout work, so a gap is settled as the layout's (a product finding) or the harness's.
@MainActor
final class MainThreadTurns {
    struct Span {
        let start: Double
        let end: Double
        var length: Double { end - start }
    }

    private(set) var turns: [Span] = []
    private(set) var layout: [Span] = []
    private var observer: CFRunLoopObserver?
    private var awake: Double?

    init() {
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue,
                                                          true, 0) { [weak self] _, activity in
            let now = CACurrentMediaTime()
            MainActor.assumeIsolated {
                guard let self else { return }
                if activity == .afterWaiting {
                    self.awake = now
                } else if let start = self.awake {
                    self.turns.append(Span(start: start, end: now))
                    self.awake = nil
                }
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
    }

    func stop() {
        if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        observer = nil
    }

    /// Wraps the layout's display-link step so each one is timed.
    func watch(_ root: LayoutRootView) {
        let original = root.driver.onFrame
        root.driver.onFrame = { [weak self] dt in
            let start = CACurrentMediaTime()
            let moving = original?(dt) ?? false
            self?.layout.append(Span(start: start, end: CACurrentMediaTime()))
            return moving
        }
    }

    /// Times one piece of layout work the test starts itself (a window resize).
    func layoutWork<T>(_ work: () -> T) -> T {
        let start = CACurrentMediaTime()
        let result = work()
        layout.append(Span(start: start, end: CACurrentMediaTime()))
        return result
    }

    /// The owner of the main thread between `from` and `to` (a missed refresh): the longest turn
    /// there, and the layout work inside it.
    func owner(from: Double, to: Double) -> String {
        let inside = turns.filter { $0.end > from && $0.start < to }
        guard let longest = inside.max(by: { $0.length < $1.length }) else {
            return "no main-thread turn recorded in the gap (the main thread waited: the display link did not fire)"
        }
        let work = layout.filter { $0.end > longest.start && $0.start < longest.end }.map(\.length).reduce(0, +)
        let share = longest.length > 0 ? work / longest.length : 0
        let side = share >= 0.5 ? "LAYOUT (product)" : "HARNESS/AppKit"
        return "\(side): longest turn \(ms(longest.length)) ms, layout work in it \(ms(work)) ms (\(Int((share * 100).rounded()))%)"
    }

    private func ms(_ seconds: Double) -> String { String(format: "%.1f", seconds * 1000) }
}
