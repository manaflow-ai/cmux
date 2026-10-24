public import Foundation

/// A live subscription; ``cancel()`` ends it (idempotent).
@MainActor
public final class PageSubscription {
    private var onCancel: (() -> Void)?
    /// What the stream's events do while the page is frozen (``PageStreamFreezing``).
    public let freezing: PageStreamFreezing

    /// - Parameters:
    ///   - freezing: How the stream's events fold while the page is frozen (``PageStreamFreezing/newest``,
    ///     ``PageStreamFreezing/members``, ``PageStreamFreezing/folded(_:)``), or that they are the
    ///     person's input and thaw it (``PageStreamFreezing/input``). No default: the provider knows
    ///     what its events mean.
    ///   - onCancel: Ends the stream; runs once.
    public init(freezing: PageStreamFreezing, onCancel: @escaping () -> Void) {
        self.freezing = freezing
        self.onCancel = onCancel
    }

    public func cancel() {
        let cancel = onCancel
        onCancel = nil
        cancel?()
    }
}

/// Which provider serves an op: the longest matching prefix wins (`cmux.app.` for native ops,
/// `cmux.history.` for the daemon relay).
@MainActor
public struct PageRoute {
    public let prefix: String
    public let provider: any PageProvider

    public init(prefix: String, provider: any PageProvider) {
        self.prefix = prefix
        self.provider = provider
    }
}
