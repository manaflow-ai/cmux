public import CmuxHomeCore
public import CmuxNextSettings
public import Foundation

/// The Messages page's `hidden` stream (`{hidden: {id: seq}, archived: [id]}`): the conversations
/// deleted from its list (``hidden``: each listed again by a message after its seq) and the
/// conversations of the Chiefs archived on this Mac (``archived``: hidden whatever comes, as the
/// native list hid them). Sent on subscribe and once per change: the rows' many updates that leave
/// the set alone send nothing.
@MainActor
public final class HomeMessagesHiddenFeed {
    /// The conversations deleted from the page's list (`HomeSidebarSource.hidden`).
    public var hidden: @MainActor () -> [ConversationID: Seq] = { [:] }
    /// The archived Chiefs' conversations (``HomeArchivedChiefs``-filtered rows).
    public var archived: @MainActor () -> [ConversationID] = { [] }
    private var listeners: [UUID: @MainActor (JSONValue) -> Void] = [:]
    private var last: JSONValue?

    public init() {}

    /// Adds a page's listener and sends it the set now.
    public func subscribe(_ key: UUID, _ onEvent: @escaping @MainActor (JSONValue) -> Void) {
        listeners[key] = onEvent
        let value = Self.json(hidden: hidden(), archived: archived())
        last = value
        onEvent(value)
    }

    public func unsubscribe(_ key: UUID) {
        listeners[key] = nil
    }

    /// The set may have changed: every page hears it when it did.
    public func publish() {
        guard !listeners.isEmpty else { return }
        let value = Self.json(hidden: hidden(), archived: archived())
        guard value != last else { return }
        last = value
        for listener in listeners.values { listener(value) }
    }

    public static func json(hidden: [ConversationID: Seq], archived: [ConversationID] = []) -> JSONValue {
        .object(["hidden": .object(hidden.reduce(into: [String: JSONValue]()) { $0[$1.key.rawValue] = .number(Double($1.value)) }),
                 "archived": .array(archived.map(\.rawValue).sorted().map(JSONValue.string))])
    }
}
