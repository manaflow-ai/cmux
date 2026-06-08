import Foundation

/// A no-op ``AuthErrorReporting`` used as the default and in tests.
///
/// Reporting auth failures is opt-in: an app that does not inject a real
/// reporter (e.g. a unit-test host, or iOS before its diagnostics reporter is
/// wired) silently drops the events rather than depending on a backend.
public struct NoopAuthErrorReporting: AuthErrorReporting {
    /// Creates a no-op reporter.
    public init() {}

    /// Discards the reported error.
    public func report(error: any Error, context: AuthErrorContext) {}
}
