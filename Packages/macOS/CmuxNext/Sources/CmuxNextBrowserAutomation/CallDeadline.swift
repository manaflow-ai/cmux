import CmuxNextWakeups
import Foundation

/// Answers a driver call by a deadline even when WebKit never calls back (a
/// promise that never settles, a page blocked by a modal dialog in a shared
/// web process). The limit is a ``Deadline`` race on `clock` (tests pass a `ManualClock`): when it passes first the
/// work is cancelled and its late answer reaches no one, as Chromium drops a late reply (a `base::OnceCallback` bound
/// to an invalidated `WeakPtr`).
@MainActor
enum CallDeadline {
    static func run(_ timeout: Duration?, what: String, clock: any Clock<Duration> = ContinuousClock(),
                    _ body: @escaping @MainActor @Sendable () async throws(DriverError) -> DriverJSON) async throws(DriverError) -> DriverJSON {
        guard let timeout else { return try await body() }
        do {
            return try await Deadline(timeout, clock: clock).run("BrowserAutomation.callDeadline") { try await body() }
        } catch let error as DriverError {
            throw error
        } catch is Deadline.Exceeded {
            throw DriverError(.timeout, "\(what): Timeout \(timeout) exceeded")
        } catch {
            throw DriverError(.closed, "\(what): the call was cancelled")
        }
    }
}
