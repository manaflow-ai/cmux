public import Foundation

/// The one `tailnet.state` read the card keeps while it is shown: at most one per daemon
/// connection (`key`), replaced when the connection changes, ended by ``stop()`` (Labs off), and
/// read again after the stream ends by itself. Each item goes to the model; an end or a refusal
/// shows the card as unavailable.
@MainActor
public final class TailnetStateFollower {
    private let model: TailnetNodeModel
    private var task: Task<Void, Never>?
    private var key: ObjectIdentifier?

    public init(model: TailnetNodeModel) {
        self.model = model
    }

    public var isFollowing: Bool { task != nil }

    /// Follows `open()`'s stream unless the read for `key` already runs.
    public func follow(key: ObjectIdentifier, open: @escaping @MainActor () async throws -> AsyncStream<TailnetNodeState>) {
        guard self.key != key || task == nil else { return }
        task?.cancel()
        self.key = key
        // task-owner: one tailnet.state read per daemon connection; ended by stop(), the next key, or the stream
        task = Task { [weak self, model] in
            do {
                for await state in try await open() {
                    guard !Task.isCancelled, self?.key == key else { return }
                    model.apply(state)
                }
            } catch {}
            guard !Task.isCancelled else { return }
            model.markUnavailable()
            // The stream ended (gap, restart, refusal): the next follow reads again.
            if self?.key == key { self?.task = nil }
        }
    }

    /// Ends the read; cancelling its stream sends `stream.cancel` to the daemon.
    public func stop() {
        task?.cancel()
        task = nil
        key = nil
    }
}
