/// A reviewed reason the main thread may block, Chrome's `ScopedAllowBlocking` friend list.
///
/// Each reason is one reviewed exception, declared here as a `static let` and nowhere else.
/// Adding one is a design decision: it needs a row in plans/cmux-next/threading-model.md
/// ("Reviewed blocking allowances") that says why the wait cannot move off the main thread, and
/// the pre-push guardrail refuses a new reason without its row. Use it only through
/// ``allowBlocking(_:_:)``.
///
/// ```swift
/// allowBlocking(.terminate) { try? journal.flushSynchronously() }
/// ```
public struct BlockingAllowance: Sendable, Equatable {
    /// The reason's name, as the threading doc lists it.
    public let name: String

    /// A reason. Internal: production reasons are the static members below; tests make their own.
    init(reviewed name: String) {
        self.name = name
    }

    /// The app is terminating: AppKit calls `applicationWillTerminate(_:)` on the main thread and
    /// the process exits right after it, so a bounded final flush there cannot delay a frame
    /// (Chrome allows blocking during browser shutdown the same way).
    public static let terminate = BlockingAllowance(reviewed: "terminate")
}
