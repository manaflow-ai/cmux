import CmuxTerminalSizing
import Foundation

/// The Mac's bookkeeping as the relay of one Cloud terminal.
///
/// The cmux-tui daemon decides the grid. The Mac forwards itself (its attach
/// lease) and every phone viewing the mirror (a relay sub-view named
/// `mobile:<client_id>`) and forwards the daemon's size state and detach
/// events back down. This value holds no transport; the mirror session turns
/// its answers into commands. Only daemons advertising
/// ``capability`` get any of it; older ones keep the legacy claim path.
public struct CloudTerminalSizingRelay: Sendable {
    /// The daemon capability that enables shared sizing.
    public static let capability = "shared-sizing-v1"

    /// One phone behind this Mac.
    public struct RelayedView: Hashable, Sendable {
        /// The relay sub-view key, `mobile:<client_id>`.
        public var view: String
        /// The phone's mobile client id.
        public var clientID: String
        /// Identity and last viewport (`id` is the view key until the host names it).
        public var participant: TerminalSizingParticipant
        /// The host's participant id for this view, once the host answered.
        public var hostParticipantID: String?
    }

    /// Where a `detached` event must go.
    public enum DetachRoute: Hashable, Sendable {
        /// This Mac's own attachment was detached.
        case mirror(TerminalDetachReason)
        /// A phone behind this Mac was detached; the Mac keeps its attachment.
        case phone(clientID: String, reason: TerminalDetachReason)
    }

    /// Whether the current daemon connection supports shared sizing.
    public private(set) var isSupported = false
    /// This Mac's participant id on the host.
    public private(set) var selfParticipantID: String?
    /// The latest host state for this terminal.
    public private(set) var state: TerminalSizingState?
    /// Phones viewing this mirror, keyed by view key.
    public private(set) var views: [String: RelayedView] = [:]
    /// When each view's latest report went to the host, until the host's
    /// state reflects it.
    private var reportSentAt: [String: Date] = [:]

    /// How long a replay waits for the host to take a phone's report before
    /// it captures anyway (a lost answer must not block the phone forever).
    public static let hostReportTimeout: TimeInterval = 3

    /// Creates an empty relay.
    public init() {}

    /// The relay sub-view key for a phone.
    ///
    /// - Parameter clientID: the phone's mobile client id.
    /// - Returns: `mobile:<client_id>`.
    public static func viewKey(clientID: String) -> String { "mobile:\(clientID)" }

    /// Starts a new daemon connection. Host ids and state belong to the old one;
    /// phones stay and are re-reported once the new connection attaches.
    ///
    /// - Parameter capabilities: the daemon's `identify` capabilities.
    public mutating func connectionStarted(capabilities: Set<String>) {
        isSupported = capabilities.contains(Self.capability)
        selfParticipantID = nil
        state = nil
        reportSentAt.removeAll()
        for key in views.keys { views[key]?.hostParticipantID = nil }
    }

    /// Records this Mac's host participant id from the attach answer.
    public mutating func attached(selfParticipantID: String?) {
        self.selfParticipantID = selfParticipantID
    }

    /// Accepts a `size-state` event or `get-size-state` answer.
    ///
    /// - Returns: whether the state is new (a newer generation or first state).
    @discardableResult
    public mutating func receive(_ next: TerminalSizingState) -> Bool {
        if let state, state == next || next.generation < state.generation { return false }
        state = next
        return true
    }

    /// Records a phone's report.
    ///
    /// - Parameters:
    ///   - clientID: the phone's mobile client id.
    ///   - participant: identity plus viewport (its `id` is ignored).
    /// - Returns: the view to report to the host, or `nil` when nothing changed.
    public mutating func phoneReported(clientID: String, participant: TerminalSizingParticipant) -> RelayedView? {
        let key = Self.viewKey(clientID: clientID)
        var next = participant
        next.id = key
        next.via = selfParticipantID
        if var existing = views[key] {
            guard existing.participant != next else { return nil }
            existing.participant = next
            views[key] = existing
            return existing
        }
        let view = RelayedView(view: key, clientID: clientID, participant: next, hostParticipantID: nil)
        views[key] = view
        return view
    }

    /// Forgets a phone (its connection closed or it left the surface).
    ///
    /// - Returns: the view key to detach on the host, if it was known.
    public mutating func phoneLeft(clientID: String) -> String? {
        reportSentAt[Self.viewKey(clientID: clientID)] = nil
        return views.removeValue(forKey: Self.viewKey(clientID: clientID))?.view
    }

    /// Records that a view's report went to the host.
    ///
    /// - Parameters:
    ///   - view: the relay sub-view key.
    ///   - date: when it was sent.
    public mutating func reportSent(view: String, at date: Date) {
        guard views[view] != nil else { return }
        reportSentAt[view] = date
    }

    /// Whether a phone's latest report is still on its way through the host:
    /// the host has not named the view yet, or its latest state does not show
    /// the reported viewport. A replay captured now would show the grid from
    /// before the phone joined, then resize. Gives up after
    /// ``hostReportTimeout``.
    ///
    /// - Parameters:
    ///   - clientID: the phone's mobile client id.
    ///   - now: the current time.
    public func awaitsHost(clientID: String, now: Date) -> Bool {
        let key = Self.viewKey(clientID: clientID)
        guard let view = views[key], let sentAt = reportSentAt[key],
              now.timeIntervalSince(sentAt) < Self.hostReportTimeout else { return false }
        guard let hostID = view.hostParticipantID,
              let row = state?.participant(hostID) else { return true }
        return row.participant.viewport != view.participant.viewport
    }

    /// Records the host participant id that answered a view report.
    public mutating func noteHostParticipant(_ participantID: String, forView view: String) {
        views[view]?.hostParticipantID = participantID
    }

    /// The host participant id a phone should treat as itself.
    public func hostParticipantID(clientID: String) -> String? {
        views[Self.viewKey(clientID: clientID)]?.hostParticipantID
    }

    /// The view key of a host participant, when it is a phone behind this Mac.
    public func view(forHostParticipant participantID: String) -> String? {
        views.values.first { $0.hostParticipantID == participantID }?.view
    }

    /// Decides where a `detached` event goes.
    ///
    /// - Parameters:
    ///   - reason: the parsed reason.
    ///   - view: the relay sub-view the event names, if any.
    /// - Returns: the route, or `nil` for an unknown sub-view.
    public mutating func routeDetached(reason: TerminalDetachReason, view: String?) -> DetachRoute? {
        guard let view else { return .mirror(reason) }
        guard let removed = views.removeValue(forKey: view) else { return nil }
        return .phone(clientID: removed.clientID, reason: reason)
    }
}
