/// Decides whether an active application owns the system frontmost process.
///
/// The policy is intentionally independent of AppKit. Callers collect the
/// current activation and process identifiers at their composition boundary,
/// then pass that snapshot here so the decision is deterministic and reusable.
public struct ApplicationFrontmostPolicy: Sendable {
    /// Creates a frontmost-process policy.
    public init() {}

    /// Returns whether the application is both active and system-frontmost.
    ///
    /// A missing frontmost process never counts as a match. Requiring the
    /// activation bit as well as the process identity preserves AppKit's
    /// active-app contract while rejecting stale Stage Manager activation.
    ///
    /// - Parameters:
    ///   - appIsActive: The activation state reported by the application.
    ///   - frontmostProcessIdentifier: The process identifier reported by the
    ///     system as frontmost, when one is available.
    ///   - currentProcessIdentifier: The process identifier of the application
    ///     evaluating the snapshot.
    /// - Returns: `true` only when the application is active and its process
    ///   identifier matches the system frontmost process.
    public func isCurrentApplicationFrontmost(
        appIsActive: Bool,
        frontmostProcessIdentifier: Int32?,
        currentProcessIdentifier: Int32
    ) -> Bool {
        appIsActive && frontmostProcessIdentifier == currentProcessIdentifier
    }
}
