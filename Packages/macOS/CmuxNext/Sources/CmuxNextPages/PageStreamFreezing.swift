public import CmuxNextSettings

/// What one page stream does with its events while its page is frozen (a hidden cmux page in
/// Chromium after the hibernation's grace, PageWebView+ChromiumCost.swift): a frozen renderer runs
/// no script, so no event may go into it, and a push from the host must not thaw it either, or a
/// page the host keeps feeding never freezes (perf-lead.md F3: hidden cmux pages cost 0 CPU and 0
/// wakeups).
///
/// The router (``PageRouter``) keeps the subscription while the page is frozen and sends nothing.
/// Events of one key fold into one held event, which goes when the page thaws: the page then
/// stands where it would stand had it applied every event, with no gap and no new subscribe, and
/// what is held is bounded by streams times keys whatever the hidden time. Only the person's own
/// input to the page (``input``) thaws it. Each provider says which its stream is when it makes
/// the ``PageSubscription``; there is no default, so a new stream decides.
///
/// ```swift
/// // The whole list in each event: the newest is the page's state.
/// return PageSubscription(freezing: .newest) { task.cancel() }
/// // Only the members that changed, each whole: the newest of each member waits.
/// return PageSubscription(freezing: .members) { stop() }
/// ```
public nonisolated struct PageStreamFreezing: Sendable {
    /// The key of an event: events with one key fold into one while the page is frozen; nil means
    /// the event must reach the page now (the person's input) and thaws it.
    let key: @Sendable (JSONValue) -> String?
    /// Folds a later event of one key into the one held for it (nil for the first): the event the
    /// page gets at the thaw.
    let fold: @Sendable (_ held: JSONValue?, _ later: JSONValue) -> JSONValue

    private init(key: @escaping @Sendable (JSONValue) -> String?,
                 fold: @escaping @Sendable (_ held: JSONValue?, _ later: JSONValue) -> JSONValue = { _, later in later }) {
        self.key = key
        self.fold = fold
    }

    /// Each event replaces the one before it: the stream's whole state, or a notice that the page
    /// reads again whatever it says. While the page is frozen only the newest is kept.
    public static let newest = PageStreamFreezing { _ in "" }

    /// Events replace earlier ones with the same `key` (a stream that carries several kinds of
    /// state, such as the agent page's theme, shortcuts and header, or one record per id). An
    /// event whose key is nil must reach the page now (the person's input, or an action they
    /// started, such as the agent page's reveal of a turn): it thaws the page and goes at once.
    ///
    /// - Parameter key: The event's key, or nil for an event that must reach the page now.
    /// - Returns: The rule.
    public static func newest(by key: @escaping @Sendable (JSONValue) -> String?) -> PageStreamFreezing {
        PageStreamFreezing(key: key)
    }

    /// Each event is an object of only the members that changed, each one whole (a page's look:
    /// `{themeCSS}`, then `{settings}`), and the page replaces those members and keeps the rest.
    /// While the page is frozen the held event gathers the newest value of every member, which is
    /// the state the page reaches by applying the events one by one.
    public static let members = PageStreamFreezing(key: { _ in "" }, fold: { held, later in
        guard case .object(var gathered) = held ?? .object([:]), case .object(let changed) = later else { return later }
        gathered.merge(changed) { _, newer in newer }
        return .object(gathered)
    })

    /// Events fold by `fold` into one held event (a change notice that names what changed: the
    /// held one names everything that changed while the page was frozen).
    ///
    /// - Parameter fold: The held event (nil for the first) and a later one, to the event the
    ///   page gets at the thaw; it must leave the page where applying both one by one would.
    /// - Returns: The rule.
    public static func folded(_ fold: @escaping @Sendable (_ held: JSONValue?, _ later: JSONValue) -> JSONValue) -> PageStreamFreezing {
        PageStreamFreezing(key: { _ in "" }, fold: fold)
    }

    /// The person's own input to the page, which must reach it now (a key pressed for the
    /// shortcut recorder, a page command such as Find): each event thaws the page. Never a push
    /// of the host's state or changes; those fold (``newest``, ``members``, ``folded(_:)``), or a
    /// page the host feeds never freezes.
    public static let input = PageStreamFreezing { _ in nil }
}
