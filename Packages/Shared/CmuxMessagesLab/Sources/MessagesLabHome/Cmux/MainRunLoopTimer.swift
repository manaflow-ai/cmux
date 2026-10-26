// cmux: the seam where the vendored AppKit views run a one-shot timer on the main actor. Not a vendored file.
import Foundation

/// A one-shot timer on the main run loop (default mode, as `Timer.scheduledTimer` on main) whose
/// action is main-actor isolated. `invalidate()` and `isValid` are the timer's.
final class MainRunLoopTimer {
    private let timer: Timer

    init(after interval: TimeInterval, _ fire: @escaping @MainActor @Sendable () -> Void) {
        timer = Timer(timeInterval: interval, repeats: false) { _ in
            // main-proof: the timer is added to the main run loop only (below), so it fires on the main thread.
            MainActor.assumeIsolated { fire() }
        }
        RunLoop.main.add(timer, forMode: .default)
    }

    var isValid: Bool { timer.isValid }

    func invalidate() { timer.invalidate() }
}
