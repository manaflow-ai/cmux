public import Foundation

/// A live subscription; ``cancel()`` ends it (idempotent).
@MainActor
public final class PageSubscription {
    private var onCancel: (() -> Void)?

    public init(onCancel: @escaping () -> Void) {
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
