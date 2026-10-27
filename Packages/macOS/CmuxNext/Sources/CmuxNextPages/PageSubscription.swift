public import Foundation

/// A live subscription; ``cancel()`` ends it (idempotent).
@MainActor
public final class PageSubscription {
    /// What the router keeps of this stream's events while the page's delivery is held (the page is
    /// hidden or frozen). Each stream declares it where it starts; there is no default.
    public let frozenDelivery: PageFrozenDelivery
    /// How the stream's event data reaches the page (``PageEventEncoding``).
    public let encoding: PageEventEncoding
    private var onCancel: (() -> Void)?

    public init(frozenDelivery: PageFrozenDelivery, encoding: PageEventEncoding = .value, onCancel: @escaping () -> Void) {
        self.frozenDelivery = frozenDelivery
        self.encoding = encoding
        self.onCancel = onCancel
    }

    public func cancel() {
        let cancel = onCancel
        onCancel = nil
        cancel?()
    }
}

/// How a stream's event data reaches the page.
public nonisolated enum PageEventEncoding: Hashable, Sendable {
    /// Each event is the value it carries, sent as the envelope's `data`.
    case value
    /// A string event is JSON text the provider holds undecoded (a daemon event line): the router
    /// sends it as the envelope's `json` and the page parses it (webviews pageClient.ts), so the app
    /// never decodes it. Mojo leaves a message's payload to the receiving stub the same way
    /// (mojo/public/cpp/bindings/lib/message.cc). Any other value goes as `data` (a `{resync: true}`).
    case jsonText
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
