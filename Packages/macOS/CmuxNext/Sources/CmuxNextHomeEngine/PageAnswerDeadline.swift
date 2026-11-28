public import Foundation

/// A host-to-page call that must not hold its caller: the page's answer when it comes within
/// `deadline`, else nil (also when the call fails). The work is cancelled at the deadline
/// (``PageCallDeadline``). The docked Home's switch asks the Channels page for its selection
/// with it (cx-ebm.59.5): a page that hangs never holds the switch.
public struct PageAnswerDeadline {
    public let deadline: Duration
    private let clock: any Clock<Duration>

    public init(_ deadline: Duration, clock: any Clock<Duration> = ContinuousClock()) {
        self.deadline = deadline
        self.clock = clock
    }

    public func answer<T: Sendable>(_ work: @escaping @MainActor @Sendable () async throws -> T) async -> T? {
        try? await PageCallDeadline.answer(within: deadline, clock: clock, onTimeout: { CancellationError() }, work)
    }
}
