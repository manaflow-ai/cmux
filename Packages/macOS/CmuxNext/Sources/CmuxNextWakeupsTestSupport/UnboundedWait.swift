internal import Testing

/// A signal wait of this target was called where nothing bounds it.
///
/// ``ManualClock/waitForSleeper()`` and ``ManualSerialExecutor/waitForJob()`` wait for a signal
/// with no bound of their own (a bound of their own would be a
/// timeout that fails falsely on a loaded runner). The current test's time limit is their only
/// bound: when a regression means the signal never comes, the time limit cancels the test, the wait
/// ends with `CancellationError`, and the failure names the test. Without a time limit the same
/// regression hangs the whole test job until CI kills it, with no test named. So each wait checks
/// the bound on entry and fails at once, every run, when the current test has none.
public struct UnboundedWait: Error, CustomStringConvertible {
    /// The wait that was called, for example `ManualClock.waitForSleeper()`.
    public let wait: String
    /// The name of the test it was called from; nil outside a Swift Testing test.
    public let test: String?

    /// What went wrong and how to fix it: give the suite a time limit.
    public var description: String {
        guard let test else {
            return "\(wait) was called outside a Swift Testing test: nothing would end it if its signal never came"
        }
        return "\(wait) in \(test): the test has no time limit, so a missing signal would hang the job; "
            + "give its suite .timeLimit(.minutes(1))"
    }
}

/// Throws ``UnboundedWait`` unless the current test has a time limit (its own, or its suite's).
///
/// - Parameter wait: The name of the wait, for the failure message.
/// - Throws: ``UnboundedWait`` when no Swift Testing test runs this task, or it has no time limit.
func requireTimeLimit(for wait: String) throws {
    guard let test = Test.current else { throw UnboundedWait(wait: wait, test: nil) }
    guard test.timeLimit != nil else { throw UnboundedWait(wait: wait, test: test.name) }
}
