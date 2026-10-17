public import Foundation
public import Observation

/// One contextual Cloud tip waiting to be shown.
///
/// The queue only orders and retires tips; the app owns their copy, icon and
/// action. `subject` carries the one value a tip names (a machine label, a
/// port), so the same tip can say "brave-otter" without a second identity.
public struct CloudHint: Hashable, Sendable {
    /// Stable identity, persisted once the tip retires. Never reuse an id for
    /// different advice: a retired id stays retired.
    public let id: String
    /// Higher shows first; equal priorities keep the order they were offered.
    public let priority: Int
    /// The value the tip names, if any.
    public let subject: String?

    public init(id: String, priority: Int = 0, subject: String? = nil) {
        self.id = id
        self.priority = priority
        self.subject = subject
    }
}

/// The one contextual-tip primitive for the Cloud panel: a priority queue that
/// shows at most one tip, never while the panel is busy, and retires each tip
/// for good once it was dismissed, acted on, or seen.
///
/// Retirement is persisted through ``CloudBannerDismissalStore``, the same
/// store that remembers dismissed Cloud banners, so tips and banners share one
/// preference key and one cross-window read-modify-write. Pending tips live in
/// memory: a tip offered this launch and never shown is offered again by the
/// event that earns it.
@MainActor
@Observable
public final class CloudHintsQueue {
    /// The persisted retirement signature. Bump only to re-show every tip.
    public static let retirementSignature = "v1"

    @ObservationIgnored
    private let dismissals: CloudBannerDismissalStore
    /// Offered tips that have not retired, in offer order.
    public private(set) var pending: [CloudHint] = []
    /// The tip on screen now, and when it appeared. It retires as seen when it
    /// leaves the screen after ``minimumSeenDuration`` (``noteDisplayEnded(at:)``),
    /// so a tip shows in one sitting and a glance that closes the panel at once
    /// does not use it up.
    public private(set) var displayed: Displayed?
    /// A tip on screen and the moment it appeared.
    public struct Displayed: Equatable, Sendable {
        public let id: String
        public let since: Date
    }

    /// How long a tip must stay on screen to count as seen.
    public static let minimumSeenDuration: TimeInterval = 2

    public init(dismissals: CloudBannerDismissalStore) {
        self.dismissals = dismissals
    }

    /// The persisted dismissal key for one tip.
    public static func dismissalID(for hintID: String) -> String {
        "cloud.hint.\(hintID)"
    }

    /// Whether a tip has already been dismissed, acted on, or seen.
    public func isRetired(_ hintID: String) -> Bool {
        dismissals.isDismissed(id: Self.dismissalID(for: hintID), signature: Self.retirementSignature)
    }

    /// Queues a tip unless it already retired. Offering a pending tip again
    /// refreshes its subject but keeps its place.
    /// - Returns: Whether the tip is pending after the call.
    @discardableResult
    public func offer(_ hint: CloudHint) -> Bool {
        guard !isRetired(hint.id) else { return false }
        if let index = pending.firstIndex(where: { $0.id == hint.id }) {
            if pending[index] != hint { pending[index] = hint }
            return true
        }
        pending.append(hint)
        return true
    }

    /// The single tip to draw now, or nil while the panel is busy (`isBlocked`:
    /// loading, an error, an open popover, another teaching card).
    public func current(isBlocked: Bool) -> CloudHint? {
        guard !isBlocked else { return nil }
        var best: CloudHint?
        for hint in pending where !isRetired(hint.id) {
            if let chosen = best, chosen.priority >= hint.priority { continue }
            best = hint
        }
        return best
    }

    /// Records that the panel drew this tip (nil: it draws none). Drawing the
    /// same tip again keeps its original start time; drawing another one, or
    /// none, ends the previous tip's display first.
    public func noteDisplayed(_ hintID: String?, at now: Date) {
        guard displayed?.id != hintID else { return }
        noteDisplayEnded(at: now)
        displayed = hintID.map { Displayed(id: $0, since: now) }
    }

    /// Drops a pending tip whose reason went away (the key was added, the port
    /// closed) without retiring it, so the same reason can earn it again.
    public func withdraw(_ hintID: String) {
        pending.removeAll { $0.id == hintID }
    }

    /// Retires a tip for good: the person closed it or did what it teaches.
    /// Retiring a tip that was never offered still prevents it later.
    public func retire(_ hintID: String) {
        pending.removeAll { $0.id == hintID }
        if displayed?.id == hintID { displayed = nil }
        guard !isRetired(hintID) else { return }
        dismissals.dismiss(id: Self.dismissalID(for: hintID), signature: Self.retirementSignature)
    }

    /// The drawn tip left the screen (the panel closed, or the panel became
    /// busy). One that stayed long enough has been seen and never returns.
    public func noteDisplayEnded(at now: Date) {
        guard let displayed else { return }
        self.displayed = nil
        if now.timeIntervalSince(displayed.since) >= Self.minimumSeenDuration {
            retire(displayed.id)
        }
    }
}
