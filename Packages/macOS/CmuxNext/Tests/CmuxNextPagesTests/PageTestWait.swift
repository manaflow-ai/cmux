import Foundation
import Testing

/// Waits for an asynchronous page-host callback with a bounded deadline.
@MainActor
enum PageTestWait {
    /// Resumes the wait once: the callback or the deadline, whichever comes first.
    ///
    /// Not generic on purpose: a generic main-actor class here crashed swift-frontend 6.3.3 in
    /// `-O` (EarlyPerfInliner on its implicit deinit, `isCallerAndCalleeLayoutConstraintsCompatible`),
    /// which broke `swift build --build-tests -c release` for every Release bench.
    private final class Once {
        var resume: ((Any?) -> Void)?

        func finish(_ value: Any?) {
            resume?(value)
            resume = nil
        }
    }

    static func value<T: Sendable>(_ stage: String, seconds: Double = 20,
                                   _ start: (@escaping (T) -> Void) -> Void) async -> T? {
        let once = Once()
        let value = await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            once.resume = { continuation.resume(returning: $0 as? T) }
            start { once.finish($0) }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(seconds))
                once.finish(nil)
            }
        }
        if value == nil { Issue.record("\(stage) timed out after \(seconds) s") }
        return value
    }
}
