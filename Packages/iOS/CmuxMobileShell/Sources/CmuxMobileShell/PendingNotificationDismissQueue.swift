public import Foundation

/// Durable outbox for phone→Mac notification dismissals.
///
/// A banner swipe can arrive when the dismiss cannot be sent: the app may be
/// background-launched from Notification Center before any scene (and therefore
/// any shell store) exists, and even with a store the attach channel is usually
/// down in the background. Dropping the swipe would leave the Mac's banner and
/// unread entry stale forever — nothing reconciles in the iOS→Mac direction.
/// So every phone-side dismiss is enqueued here first and removed only after
/// the `notification.dismiss` RPC succeeds; ``MobileShellComposite`` flushes
/// the queue on every successful (re)subscribe.
///
/// Backed by `UserDefaults` so ids survive the process being killed after a
/// background wake. Every operation reads and writes the defaults directly
/// (no in-memory copy), so the separate instances owned by the push
/// coordinator and the shell composite stay coherent over the shared storage.
/// Holds opaque notification UUIDs only, never content. `@MainActor` because
/// both writers (push coordinator, shell composite) are main-actor isolated.
@MainActor
public final class PendingNotificationDismissQueue {
    private let defaults: UserDefaults
    private static let key = "cmux.notifications.pendingMacDismissIds"
    /// FIFO bound; a phone cannot meaningfully accumulate more un-synced
    /// dismissals than this, and the Mac ignores unknown ids anyway.
    private static let capacity = 128

    /// Creates a queue over the given defaults store.
    /// - Parameter defaults: The backing store; `.standard` in the app, a
    ///   throwaway suite in tests.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The ids waiting to be delivered to the Mac, oldest first.
    public var pendingIDs: [String] {
        defaults.stringArray(forKey: Self.key) ?? []
    }

    /// Add dismissed notification ids to the outbox. Blank ids are dropped,
    /// duplicates are kept once, and the oldest entries are evicted past
    /// ``capacity``.
    public func enqueue(_ ids: [String]) {
        let trimmed = ids
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !trimmed.isEmpty else { return }
        var pending = pendingIDs
        for id in trimmed where !pending.contains(id) {
            pending.append(id)
        }
        if pending.count > Self.capacity {
            pending.removeFirst(pending.count - Self.capacity)
        }
        defaults.set(pending, forKey: Self.key)
    }

    /// Remove ids that were confirmed delivered to the Mac.
    public func remove(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        let removal = Set(ids)
        let remaining = pendingIDs.filter { !removal.contains($0) }
        if remaining.isEmpty {
            defaults.removeObject(forKey: Self.key)
        } else {
            defaults.set(remaining, forKey: Self.key)
        }
    }
}
