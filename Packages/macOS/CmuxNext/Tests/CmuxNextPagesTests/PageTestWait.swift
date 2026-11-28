import Foundation
import Testing

/// Waits for an asynchronous page-host callback with a bounded deadline.
@MainActor
enum PageTestWait {
    private final class Once<T: Sendable> {
        var continuation: CheckedContinuation<T?, Never>?

        func finish(_ value: T?) {
            continuation?.resume(returning: value)
            continuation = nil
        }
    }

    static func value<T: Sendable>(_ stage: String, seconds: Double = 20,
                                   _ start: (@escaping (T) -> Void) -> Void) async -> T? {
        let once = Once<T>()
        let value = await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            once.continuation = continuation
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
