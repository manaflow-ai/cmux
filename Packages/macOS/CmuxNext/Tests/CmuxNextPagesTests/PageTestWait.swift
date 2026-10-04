import Foundation
import Testing

/// Waits for a callback with a deadline, so a WebKit test that never gets its answer fails with a
/// named stage instead of hanging the run.
@MainActor
enum PageTestWait {
    /// What a timed-out wait prints (the shell's events and state of the host under test).
    static var onTimeout: (() async -> String)?

    private final class Once<T: Sendable> {
        var continuation: CheckedContinuation<T?, Never>?
        func finish(_ value: T?) {
            continuation?.resume(returning: value)
            continuation = nil
        }
    }

    /// `start` gets the function to call with the value; nil after `seconds`.
    static func value<T: Sendable>(_ stage: String, seconds: Double = 20, _ start: (@escaping (T) -> Void) -> Void) async -> T? {
        let once = Once<T>()
        let value: T? = await withCheckedContinuation { continuation in
            once.continuation = continuation
            start { once.finish($0) }
            // task-owner: the deadline of one test wait; a late finish is ignored
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(seconds))
                once.finish(nil)
            }
        }
        print("PAGE_TEST_STAGE \(stage): \(value == nil ? "TIMED OUT" : "ok")")
        if value == nil, let dump = onTimeout { print("PAGE_TEST_STAGE \(stage) state: \(await dump())") }
        if value == nil { Issue.record("\(stage) timed out after \(seconds) s") }
        return value
    }
}
