public import Foundation

/// Never reports pending input (tests that do not exercise the yield, headless hosts).
@MainActor
public final class NoInputPending: InputPendingSource {
    public init() {}
    public func hasPendingInput(uptime: TimeInterval) -> Bool { false }
}
