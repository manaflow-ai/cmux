import Foundation

/// A parsed mobile cross-device notification-sync request: the deduped,
/// order-preserved notification UUIDs carried by `notification.dismiss` and
/// `notification.reconcile`.
///
/// The paired phone mirrors the Mac's notification banners; when the user
/// dismisses one on the phone, or the phone reconciles its delivered banners on
/// foreground, it sends opaque notification UUIDs to the Mac. This value type
/// owns the faithful wire parsing of those ids (whitespace trimming, the
/// per-request scan cap, order-preserving UUID dedupe) and the dismiss decision
/// over a snapshot of the Mac's unread ids, so the behavior can be exhaustively
/// tested without a live notification store.
///
/// The Mac-side effects (`markRead`, the unread count, the reconcile sweep) stay
/// in the app target against the live store: this type only parses ids and
/// computes which to act on, never touches notification state, and carries only
/// opaque UUIDs, never terminal content.
public struct MobileNotificationSyncRequest: Equatable, Sendable {
    /// The maximum number of ids scanned per request.
    ///
    /// For dismiss, a phone cannot meaningfully dismiss more than this in one
    /// request (its durable outbox holds 128); for reconcile, iOS keeps only the
    /// most recent delivered notifications. Anything past the cap is a malformed
    /// or hostile frame and is ignored instead of trimmed/parsed on the main
    /// actor.
    public static let maximumIDCount = 256

    /// The parsed notification UUIDs, in first-seen request order (deduped for a
    /// dismiss request, passed straight through for a reconcile request).
    public let ids: [UUID]

    /// Parses a `notification.dismiss` id payload.
    ///
    /// Accepts either a single `notification_id` or a `notification_ids` array
    /// (matching the wire), caps the array scan at ``maximumIDCount`` elements,
    /// trims surrounding whitespace, drops empty/unparseable ids, and dedupes by
    /// UUID while preserving first-seen order so a repeated id cannot double-count
    /// or run the dismiss path twice. ``ids`` is empty when nothing valid was
    /// supplied (the caller maps empty to `invalid_params`).
    ///
    /// - Parameters:
    ///   - singleID: The raw `notification_id` param string, or `nil` when absent.
    ///   - arrayIDs: The raw `notification_ids` array elements as their `String`
    ///     representation, with `nil` for non-string elements (preserved so the
    ///     scan cap counts every element, exactly as the legacy `[Any].prefix`
    ///     did). Pass `nil` when the param is absent or not an array.
    public init(dismissSingleID singleID: String?, arrayIDs: [String?]?) {
        var rawIDs: [String] = []
        if let single = singleID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !single.isEmpty {
            rawIDs.append(single)
        }
        if let arrayIDs {
            for value in arrayIDs.prefix(Self.maximumIDCount) {
                if let string = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !string.isEmpty {
                    rawIDs.append(string)
                }
            }
        }
        var seenIDs = Set<UUID>()
        self.ids = rawIDs
            .compactMap { UUID(uuidString: $0) }
            .filter { seenIDs.insert($0).inserted }
    }

    /// Parses a `notification.reconcile` `delivered_ids` payload.
    ///
    /// Caps the scan at ``maximumIDCount`` elements, trims surrounding whitespace,
    /// and drops empty/unparseable ids. ``ids`` is empty for a valid badge-only
    /// sync. Unlike the dismiss parse, ids are not deduped (the legacy reconcile
    /// path passed them straight through), matching the wire exactly.
    ///
    /// - Parameter arrayIDs: The raw `delivered_ids` array elements as their
    ///   `String` representation, with `nil` for non-string elements (preserved
    ///   so the scan cap counts every element). Pass `nil` when the param is
    ///   absent or not an array.
    public init(deliveredArrayIDs arrayIDs: [String?]?) {
        guard let arrayIDs else {
            self.ids = []
            return
        }
        self.ids = arrayIDs.prefix(Self.maximumIDCount).compactMap { value -> UUID? in
            guard let string = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !string.isEmpty else {
                return nil
            }
            return UUID(uuidString: string)
        }
    }

    /// Selects the parsed ids that should be marked read, given a snapshot of the
    /// Mac's currently-unread notification ids.
    ///
    /// Only ids that are currently unread transition unread→read, so unknown or
    /// already-read ids are no-ops: a stale/duplicate phone dismiss reports 0
    /// rather than a misleading hit. The result preserves request order; the
    /// dismissed count is `result.count`.
    ///
    /// - Parameter unreadIDs: The set of notification ids currently unread on the Mac.
    /// - Returns: The ids the caller should `markRead`, in request order.
    public func dismissPlan(unreadIDs: Set<UUID>) -> [UUID] {
        ids.filter { unreadIDs.contains($0) }
    }
}
