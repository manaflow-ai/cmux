public import Foundation

/// Never reports pending input (tests that do not exercise the yield, headless hosts).
@MainActor
public final class NoInputPending: InputPendingSource {
    /// A source that reports no input.
    public init() {}
    /// Always false.
    public func hasPendingInput(uptime: TimeInterval) -> Bool { false }
}
