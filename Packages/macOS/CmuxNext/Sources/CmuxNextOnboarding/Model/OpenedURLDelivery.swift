public import Foundation

/// Keeps URLs AppKit delivers before launch finishes, then hands each to the
/// ready app exactly once. Browser callbacks use the same path as later URLs.
@MainActor
public final class OpenedURLDelivery {
    private var pending: [URL] = []
    private var deliver: ((URL) -> Void)?

    public init() {}

    public func receive(_ url: URL) {
        if let deliver { deliver(url) } else { pending.append(url) }
    }

    public func start(_ deliver: @escaping (URL) -> Void) {
        guard self.deliver == nil else { return }
        self.deliver = deliver
        let waiting = pending
        pending.removeAll()
        for url in waiting { deliver(url) }
    }
}
