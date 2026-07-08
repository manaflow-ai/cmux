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
/// Holds opaque notification UUIDs plus the owning Mac id only, never content.
/// `@MainActor` because both writers (push coordinator, shell composite) are
/// main-actor isolated.
@MainActor
public final class PendingNotificationDismissQueue {
    private let defaults: UserDefaults
    private static let key = "cmux.notifications.pendingMacDismissIds"
    private static let idKey = "id"
    private static let macDeviceIDKey = "macDeviceId"
    /// FIFO bound; a phone cannot meaningfully accumulate more un-synced
    /// dismissals than this, and the Mac ignores unknown ids anyway.
    private static let capacity = 128

    /// Creates a queue over the given defaults store.
    /// - Parameter defaults: The backing store; `.standard` in the app, a
    ///   throwaway suite in tests.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The dismisses waiting to be delivered, oldest first. Older builds stored
    /// only a string array of ids; those are still readable and route through the
    /// foreground Mac on the next flush.
    public var pendingDismisses: [(id: String, macDeviceID: String?)] {
        if let rows = defaults.array(forKey: Self.key) as? [[String: String]] {
            return rows.compactMap { row in
                guard let id = row[Self.idKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !id.isEmpty else { return nil }
                let mac = row[Self.macDeviceIDKey]?.trimmingCharacters(in: .whitespacesAndNewlines)
                return (id: id, macDeviceID: mac?.isEmpty == false ? mac : nil)
            }
        }
        return (defaults.stringArray(forKey: Self.key) ?? []).map { (id: $0, macDeviceID: nil) }
    }

    /// The ids waiting to be delivered, oldest first.
    public var pendingIDs: [String] {
        pendingDismisses.map(\.id)
    }

    /// Add dismissed notification ids to the outbox. Blank ids are dropped,
    /// duplicates are kept once, and the oldest entries are evicted past
    /// ``capacity``.
    public func enqueue(_ ids: [String], macDeviceID: String? = nil) {
        let mac = macDeviceID?.trimmingCharacters(in: .whitespacesAndNewlines)
        enqueue(ids.map { (id: $0, macDeviceID: mac?.isEmpty == false ? mac : nil) })
    }

    /// Add dismissed notification ids with their owning Mac ids to the outbox.
    public func enqueue(_ dismisses: [(id: String, macDeviceID: String?)]) {
        let trimmed = dismisses.compactMap { dismiss -> (id: String, macDeviceID: String?)? in
            let id = dismiss.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { return nil }
            let mac = dismiss.macDeviceID?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (id: id, macDeviceID: mac?.isEmpty == false ? mac : nil)
        }
        guard !trimmed.isEmpty else { return }
        var pending = pendingDismisses
        for dismiss in trimmed where !pending.contains(where: { $0.id == dismiss.id && $0.macDeviceID == dismiss.macDeviceID }) {
            pending.append(dismiss)
        }
        if pending.count > Self.capacity {
            pending.removeFirst(pending.count - Self.capacity)
        }
        defaults.set(
            pending.map { dismiss in
                var row = [Self.idKey: dismiss.id]
                if let mac = dismiss.macDeviceID {
                    row[Self.macDeviceIDKey] = mac
                }
                return row
            },
            forKey: Self.key
        )
    }

    /// Remove ids that were confirmed delivered to the Mac.
    public func remove(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        let removal = Set(ids)
        let remaining = pendingDismisses.filter { !removal.contains($0.id) }
        save(remaining)
    }

    /// Remove dismisses that were confirmed delivered to the owning Mac.
    public func remove(_ dismisses: [(id: String, macDeviceID: String?)]) {
        guard !dismisses.isEmpty else { return }
        func key(_ dismiss: (id: String, macDeviceID: String?)) -> String {
            "\(dismiss.macDeviceID ?? "")\u{1F}\(dismiss.id)"
        }
        let removal = Set(dismisses.map(key))
        let remaining = pendingDismisses.filter { !removal.contains(key($0)) }
        save(remaining)
    }

    private func save(_ dismisses: [(id: String, macDeviceID: String?)]) {
        let remaining = dismisses.filter { !$0.id.isEmpty }
        if remaining.isEmpty {
            defaults.removeObject(forKey: Self.key)
        } else {
            defaults.set(
                remaining.map { dismiss in
                    var row = [Self.idKey: dismiss.id]
                    if let mac = dismiss.macDeviceID {
                        row[Self.macDeviceIDKey] = mac
                    }
                    return row
                },
                forKey: Self.key
            )
        }
    }
}
