/// Re-entrancy guard that suppresses `NSWindow.makeFirstResponder` while a
/// browser panel performs first-responder-churning work (e.g. revealing the
/// WebKit inspector) so AppKit does not walk a tearing-down responder chain.
///
/// Faithfully lifted from the app target's `cmuxWindowFirstResponderBypassDepth`
/// global plus the `cmuxWithWindowFirstResponderBypass` /
/// `cmuxIsWindowFirstResponderBypassActive` free functions. The depth counter
/// and its semantics are unchanged: the bypass is active while any
/// ``withBypass(_:)`` call is on the stack, and the counter never drops below
/// zero.
///
/// Construct one instance at the composition root and inject it; the app-target
/// `NSWindow.makeFirstResponder` swizzle reads ``isActive`` and `BrowserPanel`
/// wraps the devtools-reveal in ``withBypass(_:)``.
///
/// The depth counter carries no actor isolation: every access is confined to the
/// main thread by contract (first-responder mutation is main-thread-only in
/// AppKit, and the devtools reveal runs on the main thread). This mirrors the
/// sanctioned main-thread-confined disposition of ``AccessibilityWindowCache``.
///
/// `@unchecked Sendable` solely so the composition root may hold the instance as
/// a non-isolated stored property reachable from the non-isolated
/// `NSWindow.makeFirstResponder` swizzle. There is no actual data race because
/// every read and write happens on the main thread.
public final class BrowserFirstResponderBypass: @unchecked Sendable {
    private var depth = 0

    public init() {}

    /// `true` while a ``withBypass(_:)`` call is on the stack. The
    /// `NSWindow.makeFirstResponder` swizzle reads this to short-circuit.
    public var isActive: Bool {
        depth > 0
    }

    /// Runs `body` with the first-responder bypass active, restoring the prior
    /// depth afterward. Re-entrant: nested calls keep the bypass active until the
    /// outermost call returns.
    @discardableResult
    public func withBypass<T>(_ body: () -> T) -> T {
        depth += 1
        defer {
            depth = max(0, depth - 1)
        }
        return body()
    }
}
