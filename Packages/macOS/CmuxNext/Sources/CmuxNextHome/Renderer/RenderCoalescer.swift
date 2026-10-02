import CoreFoundation
import Foundation

/// Runs `body` once per run-loop pass, just before the run loop sleeps and
/// before Core Animation commits (its observer has order 2,000,000), when
/// something asked for it. Scroll events, page chunks and source changes in
/// one pass become one transcript render. It never wakes the run loop: the
/// observer only runs on passes that other events caused.
final class RenderCoalescer {
    private var observer: CFRunLoopObserver?
    private(set) var isDirty = false
    private let body: () -> Void

    init(_ body: @escaping () -> Void) { self.body = body }

    isolated deinit { stop() }

    func setNeeded() {
        isDirty = true
        guard observer == nil else { return }
        let made = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 1_999_000) {
            [weak self] _, _ in
            MainActor.assumeIsolated { self?.flush() }
        }
        guard let made else { return }
        CFRunLoopAddObserver(CFRunLoopGetMain(), made, .commonModes)
        observer = made
    }

    /// Runs a pending render now (tests, bench).
    func flush() {
        guard isDirty else { return }
        isDirty = false
        body()
    }

    func stop() {
        if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        observer = nil
        isDirty = false
    }
}
