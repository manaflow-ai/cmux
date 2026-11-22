public import Foundation
import Synchronization

/// The host's record of the user's last real gesture in a pane (a key or mouse event in its web
/// view, or a native action such as a permission shortcut). Each gesture gives two single-use
/// credits: one GRANT (a frame that grants something, ``AcpmuxPaneMethods/needsGesture(_:options:)``,
/// ``consume()``) and one SCOPE-ADD (one attach of a session that is not yet the pane's,
/// ``consumeScope()``). Using one leaves the other. A gesture older than ``lifetime`` is gone (it
/// covers a prompt held while a harness starts). Page script cannot set it.
@MainActor public final class AgentPaneUserGestures {
    public static let lifetime: TimeInterval = 30
    private var last: TimeInterval?
    /// The same gesture's scope-add credit.
    private var lastScope: TimeInterval?
    private let now: @MainActor () -> TimeInterval

    public init(now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
    }

    /// A real user event reached the pane.
    public func record() {
        last = now()
        lastScope = last
    }

    /// Uses the gesture: true once per recorded gesture, false when there is none or it expired.
    public func consume() -> Bool {
        guard let last else { return false }
        self.last = nil
        return now() - last <= Self.lifetime
    }

    public var isAvailable: Bool { last.map { now() - $0 <= Self.lifetime } ?? false }

    /// Uses the gesture's scope-add credit (one attach of a session that is not yet the pane's):
    /// true once per recorded gesture; the grant credit stays.
    public func consumeScope() -> Bool {
        guard let lastScope else { return false }
        self.lastScope = nil
        return now() - lastScope <= Self.lifetime
    }

    /// The record for logs and the DEBUG `debug.agent_pane gesture_state` verb: whether a gesture
    /// is available, its age in seconds, and the outstanding tickets. Never a ticket value.
    public var debugState: (available: Bool, scopeAvailable: Bool, ageSeconds: Double?, tickets: Int) {
        (isAvailable, lastScope.map { now() - $0 <= Self.lifetime } ?? false, last.map { now() - $0 }, tickets.count)
    }

    /// ``debugState`` as one log field.
    public var debugDescription: String {
        let age = last.map { String(format: "%.3f", now() - $0) } ?? "none"
        return "gestureAvailable=\(isAvailable) scopeAvailable=\(debugState.scopeAvailable) gestureAge=\(age) tickets=\(tickets.count)"
    }

    /// How long a reserved gesture waits for its frame (a pick held while a harness starts).
    public nonisolated static let ticketLifetime: TimeInterval = 60
    /// How long a prompt held for the folder trust answer keeps its send's gesture.
    public nonisolated static let heldPromptLifetime: TimeInterval = 600

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
        tickets = tickets.filter { at - $0.value.at <= $0.value.intent.lifetime
            && !($0.value.connection == connection && $0.value.intent.slot == intent.slot) }
        let ticket = UUID().uuidString
        tickets[ticket] = Ticket(connection: connection, intent: intent, at: at)
        lastTicket = ticket
        return ticket
    }

    /// Spends `ticket` (even when it does not match) and says whether it allows this frame: the
    /// same connection, within its lifetime, and the frame is its pick.
    public func redeem(_ ticket: String, connection: Int, method: String?, params: [String: Any]) -> Bool {
        redeem(ticket, connection: connection, pick: AgentPaneGesturePick(method: method, params: params))
    }

    /// Spends `ticket`; true when it was this connection's, still fresh, and for exactly `pick`.
    public func redeem(_ ticket: String, connection: Int, pick: AgentPaneGesturePick?) -> Bool {
        guard let held = tickets.removeValue(forKey: ticket) else { return false }
        return held.connection == connection && now() - held.at <= held.intent.lifetime && held.intent.matches(pick)
    }

    /// Drops every ticket (a reconnect, the end of a harness switch, the page's release).
    public func clearTickets() { tickets.removeAll() }

    var ticketCount: Int { tickets.count }
    /// The last ticket issued (tests replay it).
    private(set) var lastTicket: String?
}

/// The permission options the daemon sent this pane, so the relay knows whether an answer allows or
/// denies. Fed off the main thread, from one parse of each daemon frame (ad349, round 8): options are
/// read only from their fixed places, never by walking the frame, so model content (a tool call's
/// raw input, a transcript update) can never make an option a deny:
/// - `_acpmux/permission_pending`: `params.permissionId`, `params.request.options`;
/// - a `permission_request` event the daemon recorded (`dir` "mux") in the `_acpmux/event` stream,
///   or in `result.events` of a reply to `_acpmux/attach` or `_acpmux/events`: `msg.permissionId`,
///   `msg.request.options`.
/// An option id seen with two kinds counts as allow (it needs a gesture). A request whose
/// `request.toolCall._meta.acpmux.question` (the daemon's normalized question) is an object is a
/// question; its items' ids and prompts are the keys its `answers` may use (``questionKeys(permissionId:)``).
/// A permission seen once without a question is no question (as the policy crate's `is_question`).
public nonisolated final class AcpmuxPermissionOptions: Sendable {
    /// permissionId -> optionId -> whether every kind seen for it denies (`reject_*`).
    private let denies = Mutex<[String: [String: Bool]]>([:])
    /// permissionId -> the item ids and prompts of its question; nil once a request without a
    /// question was seen for it.
    private let questions = Mutex<[String: Set<String>?]>([:])

    /// The replies whose `result.events` hold the daemon's history.
    public static let historyReplies: Set<String> = ["_acpmux/attach", "_acpmux/events"]

    public init() {}

    /// Records the options of every permission request in `text` (a daemon frame, not a reply).
    public func observe(_ text: String) {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return }
        observe(object, replyTo: nil)
    }

    /// The same for a parsed daemon frame; `method` is the request a reply answers.
    public func observe(_ object: [String: Any], replyTo method: String?) {
        var found: [(permission: String, option: String, denies: Bool)] = []
        var asked: [(permission: String, keys: Set<String>?)] = []
        func request(_ record: [String: Any]?) {
            guard let record, let permission = record["permissionId"] as? String else { return }
            let request = record["request"] as? [String: Any]
            asked.append((permission, request.flatMap(Self.questionKeys)))
            guard let options = request?["options"] as? [Any] else { return }
            for case let option as [String: Any] in options {
                guard let id = option["optionId"] as? String, let kind = option["kind"] as? String else { continue }
                found.append((permission, id, kind.hasPrefix("reject")))
            }
        }
        func event(_ value: Any?) {
            guard let event = value as? [String: Any], event["kind"] as? String == "permission_request",
                  event["dir"] as? String == "mux" else { return }
            request(event["msg"] as? [String: Any])
        }
        switch object["method"] as? String {
        case "_acpmux/permission_pending": request(object["params"] as? [String: Any])
        case "_acpmux/event": event(object["params"])
        case nil:
            guard let method, Self.historyReplies.contains(method),
                  let events = (object["result"] as? [String: Any])?["events"] as? [Any] else { return }
            events.forEach(event)
        default: return
        }
        if !asked.isEmpty {
            questions.withLock { questions in
                for entry in asked {
                    let before: Set<String>? = questions[entry.permission] ?? Set<String>()
                    // updateValue keeps a nil (no question) entry; a subscript set of nil removes it.
                    questions.updateValue(before.flatMap { old in entry.keys.map { old.union($0) } }, forKey: entry.permission)
                }
            }
        }
        guard !found.isEmpty else { return }
        denies.withLock { denies in
            for entry in found {
                denies[entry.permission, default: [:]][entry.option] = (denies[entry.permission]?[entry.option] ?? true) && entry.denies
            }
        }
    }

    /// The keys `answers` may use for `permissionId`: its question's item ids and prompts; nil
    /// when the pane never saw it as a question (a tool permission, or an unknown one).
    public func questionKeys(permissionId: String) -> Set<String>? {
        questions.withLock { $0[permissionId] ?? nil }
    }

    /// The item ids and prompts of `request.toolCall._meta.acpmux.question`, when it is an object.
    static func questionKeys(_ request: [String: Any]) -> Set<String>? {
        let tool = request["toolCall"] as? [String: Any]
        let acpmux = (tool?["_meta"] as? [String: Any])?["acpmux"] as? [String: Any]
        guard let question = acpmux?["question"] as? [String: Any] else { return nil }
        var keys = Set<String>()
        for case let item as [String: Any] in question["items"] as? [Any] ?? [] {
            for key in ["id", "prompt"] { if let value = item[key] as? String { keys.insert(value) } }
        }
        return keys
    }

    /// True only when `optionId` is a known deny of `permissionId`; an unknown option counts as allow.
    public func isDeny(permissionId: String, optionId: String) -> Bool {
        denies.withLock { $0[permissionId]?[optionId] == true }
    }
}
