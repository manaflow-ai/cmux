public import AppKit
internal import ObjectiveC

extension NSApplication {
    /// Runs NSApplication's own `reportException:` on this application, through the Objective-C
    /// runtime, so no Swift executor check runs before it.
    ///
    /// For a `nonisolated` override of `reportException(_:)`: `super.reportException` is
    /// main-actor isolated in the SDK, and asserting the main actor reads the Swift runtime's
    /// executor record, which an Objective-C exception that unwound a Swift job leaves dead; that
    /// read segfaulted (#44899).
    ///
    /// ```swift
    /// nonisolated override func reportException(_ exception: NSException) {
    ///     appKitReportException(exception)
    /// }
    /// ```
    ///
    /// - Parameter exception: The exception AppKit caught.
    public nonisolated func appKitReportException(_ exception: NSException) {
        typealias Report = @convention(c) (NSApplication, Selector, NSException) -> Void
        let selector = #selector(NSApplication.reportException(_:))
        guard let implementation = class_getMethodImplementation(NSApplication.self, selector) else { return }
        unsafeBitCast(implementation, to: Report.self)(self, selector, exception)
    }
}
