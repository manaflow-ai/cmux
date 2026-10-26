public import CmuxNextSettings
public import Foundation

/// The owner side of one or more page namespaces: a relay to the daemon (`cmux.history.*` ->
/// `history.*` v2 ops) or the app's native UI ops. Providers never see a call the page's
/// descriptor does not admit; params arrive without an `origin` (the context has it).
@MainActor
public protocol PageProvider: AnyObject {
    var eventsAfterSubscribeReply: Bool { get }
    /// Answers one call or throws ``PageError``.
    func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue
    /// Starts an event stream with the page's `filter` (an object, possibly empty); `onEvent` runs
    /// on the main actor for each event, in order. The returned subscription names the stream's
    /// ``PageFrozenDelivery``: what the router keeps while the page is hidden or frozen.
    func subscribe(_ stream: String, filter: JSONValue, context: PageCallContext,
                   onEvent: @escaping @MainActor (JSONValue) -> Void) async throws -> PageSubscription

    func eventDeliveryDropped(stream: String, data: JSONValue, publicationID: UInt64?)
    var eventDeliveryID: UInt64? { get }
}

public extension PageProvider {
    var eventsAfterSubscribeReply: Bool { false }

    func subscribe(_ stream: String, filter: JSONValue, context: PageCallContext,
                   onEvent: @escaping @MainActor (JSONValue) -> Void) async throws -> PageSubscription {
        throw PageError.unknownOp(stream)
    }

    var eventDeliveryID: UInt64? { nil }
    func eventDeliveryDropped(stream: String, data: JSONValue) {}
    func eventDeliveryDropped(stream: String, data: JSONValue, publicationID: UInt64?) {}
}

/// What ``PageRouter`` keeps of one stream's events while the page's delivery is held (hidden or
/// frozen, webui-DESIGN.md "Lifecycle"). It replaces the backpressure Chrome's WebUI handlers get
/// from Mojo: a frozen page runs no script, so the router must not queue without bound for it.
/// Release sends what was kept in arrival order with fresh `seq` numbers, so the page never sees a
/// seq skip; a stream that lost events gets `gap: true` on its first released event and resyncs
/// (pane-protocol.md decision 15). Each dropped event calls the provider's
/// ``PageProvider/eventDeliveryDropped(stream:data:publicationID:)`` once.
public nonisolated enum PageFrozenDelivery: Hashable, Sendable {
    /// A state stream: each event replaces the last. Keeps the newest; no gap.
    case latest
    /// A delta stream the page can rebuild with a fresh read: keeps the newest, and marks a gap
    /// when it dropped any, so the page re-reads.
    case resync
    /// Keeps the newest `limit` events (at least 1); older ones drop and mark a gap.
    case queue(Int)
    /// Never drops. When one stream holds ``orderedHalfFull`` events the router tells
    /// ``PageDeliveryLifecycle/orderedDeliveryHalfFull()`` once per hold: the page leaves Frozen and
    /// stays hidden.
    case ordered

    /// Half of the largest provider buffer (AgentPageProvider keeps 8,192 events).
    public static let orderedHalfFull = 4_096

    /// How many held events the stream keeps; nil keeps all.
    var keeps: Int? {
        switch self {
        case .latest, .resync: 1
        case .queue(let limit): max(1, limit)
        case .ordered: nil
        }
    }

    /// Whether a drop must reach the page as a gap (the page resyncs).
    var dropMarksGap: Bool {
        switch self {
        case .latest, .ordered: false
        case .resync, .queue: true
        }
    }
}

/// The router's link to its page's lifecycle (PageLifecycle, p13-webui-022). Every call runs in the
/// caller's turn, so a thaw happens before the envelope that needed it is sent.
@MainActor
public protocol PageDeliveryLifecycle: AnyObject {
    /// Thaws the page now if it is frozen (it may stay hidden); a no-op otherwise. The router calls
    /// it before a built-in command or a host call reaches the page, so a page call never waits out
    /// a deadline because the page was frozen.
    func thawForDelivery()
    /// An `.ordered` stream holds ``PageFrozenDelivery/orderedHalfFull`` events.
    func orderedDeliveryHalfFull()
}
