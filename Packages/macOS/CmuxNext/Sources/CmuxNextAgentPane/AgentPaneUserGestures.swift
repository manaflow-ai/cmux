public import Foundation
import Synchronization

/// The host's record of the user's last real gesture in a pane (a key or mouse event in its web
/// view, or a native action such as a permission shortcut). A frame that GRANTS something
/// (``AcpmuxPaneMethods/needsGesture(_:options:)``) consumes it: one gesture per grant, and the
/// record is cleared when used. A gesture older than ``lifetime`` is gone (it covers a prompt held
/// while a harness starts). Page script cannot set it.
@MainActor public final class AgentPaneUserGestures {
    public static let lifetime: TimeInterval = 30
    private var last: TimeInterval?
    private let now: @MainActor () -> TimeInterval

    public init(now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
    }

    /// A real user event reached the pane.
    public func record() { last = now() }

    /// Uses the gesture: true once per recorded gesture, false when there is none or it expired.
    public func consume() -> Bool {
        guard let last else { return false }
        self.last = nil
        return now() - last <= Self.lifetime
    }

    public var isAvailable: Bool { last.map { now() - $0 <= Self.lifetime } ?? false }

    /// How long a reserved gesture waits for its frame (a pick held while a harness starts).
    public static let ticketLifetime: TimeInterval = 60

    struct Ticket {
        var connection: Int
        var intent: AgentPaneGestureIntent
        var at: TimeInterval
    }

    private var tickets: [String: Ticket] = [:]

    /// Binds the current gesture to one pick the page sends later (a pick held behind a harness
    /// switch) on `connection`: consumes the gesture and returns a single-use ticket, nil when
    /// there is none. One outstanding ticket per slot per connection (``AgentPaneGestureIntent/slot``):
    /// a new one revokes the older.
    public func reserve(connection: Int, intent: AgentPaneGestureIntent) -> String? {
        guard consume() else { return nil }
        let at = now()
        tickets = tickets.filter { at - $0.value.at <= Self.ticketLifetime
            && !($0.value.connection == connection && $0.value.intent.slot == intent.slot) }
        let ticket = UUID().uuidString
        tickets[ticket] = Ticket(connection: connection, intent: intent, at: at)
        lastTicket = ticket
        return ticket
    }

    /// Spends `ticket` (even when it does not match) and says whether it allows this frame: the
    /// same connection, within its lifetime, and the frame is its pick.
    public func redeem(_ ticket: String, connection: Int, method: String?, params: [String: Any]) -> Bool {
        guard let held = tickets.removeValue(forKey: ticket) else { return false }
        return held.connection == connection && now() - held.at <= Self.ticketLifetime
            && held.intent.matches(method: method, params: params)
    }

    /// Drops every ticket (a reconnect, the end of a harness switch, the page's release).
    public func clearTickets() { tickets.removeAll() }

    var ticketCount: Int { tickets.count }
    /// The last ticket issued (tests replay it).
    private(set) var lastTicket: String?
}

/// The permission options the daemon sent this pane (`_acpmux/permission_pending` and attach
/// history), so the relay knows whether an answer allows or denies. Fed off the main thread.
public nonisolated final class AcpmuxPermissionOptions: Sendable {
    /// permissionId -> the option ids whose kind denies (`reject_*`).
    private let denies = Mutex<[String: Set<String>]>([:])

    public init() {}

    /// Records the options of every permission request in `text` (a daemon frame).
    public func observe(_ text: String) {
        guard text.contains("optionId"),
              let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) else { return }
        var found: [String: Set<String>] = [:]
        Self.collect(object, permissionId: nil, into: &found)
        guard !found.isEmpty else { return }
        denies.withLock { $0.merge(found) { $0.union($1) } }
    }

    /// True only when `optionId` is a known deny of `permissionId`; an unknown option counts as allow.
    public func isDeny(permissionId: String, optionId: String) -> Bool {
        denies.withLock { $0[permissionId]?.contains(optionId) ?? false }
    }

    private static func collect(_ value: Any, permissionId: String?, into found: inout [String: Set<String>]) {
        if let object = value as? [String: Any] {
            let id = (object["permissionId"] as? String) ?? permissionId
            if let id, let options = object["options"] as? [[String: Any]] {
                for option in options {
                    guard let optionId = (option["optionId"] ?? option["id"]) as? String,
                          let kind = option["kind"] as? String, kind.hasPrefix("reject") else { continue }
                    found[id, default: []].insert(optionId)
                }
            }
            for inner in object.values { collect(inner, permissionId: id, into: &found) }
        } else if let list = value as? [Any] {
            for inner in list { collect(inner, permissionId: permissionId, into: &found) }
        }
    }
}
