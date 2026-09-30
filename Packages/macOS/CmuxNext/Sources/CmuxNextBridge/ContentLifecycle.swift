/// The lifecycle of every tab's content view (terminal surface, WebKit or
/// Chromium page), one record per tab, owned by the App's content cache
/// (plans/cmux-next/tab-lifecycle.md).
///
/// Phases:
///
/// - `unmounted`: no content object (never shown, or a terminal surface the
///   warm set released; showing it creates or re-attaches it).
/// - `mountedVisible`: the content exists and draws in its pane.
/// - `mountedHidden`: the content exists, hidden and paused (warm).
/// - `hibernated`: the content was released to save memory; the tab keeps
///   its restorable state and a snapshot for the hover preview.
/// - `restoring`: waking from hibernation (or first creation of a page that
///   is created asynchronously); shown when the restore completes.
/// - `crashed`: the page's renderer ended; the pane shows the sad tab.
///
/// Every visibility transition is a typed event and bumps the tab's
/// `generation`. Effects carry the generation they were issued for, and an
/// asynchronous completion (page created, snapshot rendered, restore done)
/// is applied only while its generation is current (`accepts`). So a late
/// completion for an older selection can never show, hide or reparent the
/// view of a newer one: that is the rule the disappearing-page bug broke.
///
/// Visibility effects (`reveal`, `conceal`) are applied synchronously by
/// the caller, in order, before the next event; nothing between an event
/// and its effects awaits.
public struct ContentLifecycle<Key: Hashable & Sendable>: Sendable {
    public enum Phase: String, Hashable, Sendable, Codable {
        case unmounted, mountedVisible, mountedHidden, hibernated, restoring, crashed
    }

    /// Identifies one issued effect. A snapshot after `conceal` is kept only
    /// while `accepts` (no later show or hide); a `mount`/`restore`
    /// completion is applied only when it answers the outstanding operation
    /// (the tab was not closed, released or hibernated again meanwhile).
    public struct Token: Hashable, Sendable, CustomStringConvertible {
        public let generation: UInt64
        public init(_ generation: UInt64) { self.generation = generation }
        public var description: String { "g\(generation)" }
    }

    public enum Event: Hashable, Sendable {
        /// A visible pane shows the tab (the ledger's rendering became true).
        case show(Key)
        /// The tab stopped showing (another tab selected, pane away or gone).
        case hide(Key)
        /// Content that did not exist was created and is live (a terminal
        /// surface attached, a page created or restored). `token` is the one
        /// the `mount`/`restore` effect carried.
        case mounted(Key, Token)
        /// Creation or restore failed; the tab falls back to unmounted.
        case mountFailed(Key, Token)
        /// The content was released without hibernation (warm set eviction,
        /// daemon restart): the next show creates it again.
        case released(Key)
        /// The policy (time, memory pressure) or the user hibernates a
        /// hidden tab.
        case hibernate(Key)
        /// Restore a hibernated tab without showing it (the user's Wake Tab,
        /// or a navigation in a hibernated tab).
        case wake(Key)
        /// The page's renderer ended.
        case crashed(Key)
        /// A crashed page loaded again (reload after the sad tab).
        case recovered(Key)
        /// The tab closed: forget it.
        case removed(Key)
    }

    public enum Effect: Hashable, Sendable {
        /// Create the content (async for Chromium pages and terminal
        /// attach); answer with `.mounted(key, token)`.
        case mount(Key, Token)
        /// Make the content draw, now (synchronous).
        case reveal(Key, Token)
        /// Hide and pause the content, now (synchronous). Afterwards the
        /// caller may render a preview snapshot asynchronously; it keeps the
        /// image only while `accepts(key, token)` and the tab stays hidden.
        case conceal(Key, Token)
        /// Save the restorable state and a snapshot, then release the
        /// content (hibernation).
        case release(Key, Token)
        /// Recreate hibernated content from its saved state; answer with
        /// `.mounted(key, token)`.
        case restore(Key, Token)
    }

    public struct Record: Hashable, Sendable {
        public fileprivate(set) var phase: Phase = .unmounted
        /// Bumped by every event that changes what the tab should show.
        public fileprivate(set) var generation: UInt64 = 0
        /// The tab should be visible (a visible pane shows it).
        public fileprivate(set) var wantsVisible = false
        /// The token of the outstanding mount or restore, if any.
        public fileprivate(set) var pending: Token?
        /// The outstanding operation restores hibernated content (a failure
        /// returns the tab to `hibernated`, keeping its saved state).
        public fileprivate(set) var restoresHibernated = false
    }

    private var records: [Key: Record] = [:]
    private var nextGeneration: UInt64 = 0

    public init() {}

    // MARK: Queries

    public func record(_ key: Key) -> Record? { records[key] }

    public func phase(_ key: Key) -> Phase { records[key]?.phase ?? .unmounted }

    /// True while `token` is the latest one issued for `key`: a completion
    /// carrying an older token is stale and must change nothing.
    public func accepts(_ key: Key, _ token: Token) -> Bool {
        records[key]?.generation == token.generation
    }

    /// Keys in `phase`.
    public func keys(in phase: Phase) -> [Key] {
        records.compactMap { $0.value.phase == phase ? $0.key : nil }
    }

    // MARK: Transitions

    /// Applies `event` and returns the effects to perform now, in order.
    public mutating func send(_ event: Event) -> [Effect] {
        switch event {
        case .show(let key):
            var record = records[key] ?? Record()
            record.wantsVisible = true
            let token = bump(&record)
            var effects: [Effect] = []
            switch record.phase {
            case .unmounted:
                record.phase = .restoring
                record.pending = token
                record.restoresHibernated = false
                effects = [.mount(key, token)]
            case .hibernated:
                record.phase = .restoring
                record.pending = token
                record.restoresHibernated = true
                effects = [.restore(key, token)]
            case .restoring:
                // Still coming: the completion shows it (it reads
                // `wantsVisible` when it lands).
                effects = []
            case .mountedHidden, .mountedVisible:
                record.phase = .mountedVisible
                effects = [.reveal(key, token)]
            case .crashed:
                effects = [.reveal(key, token)]
            }
            records[key] = record
            return effects

        case .hide(let key):
            guard var record = records[key] else { return [] }
            record.wantsVisible = false
            let token = bump(&record)
            var effects: [Effect] = []
            switch record.phase {
            case .mountedVisible:
                record.phase = .mountedHidden
                effects = [.conceal(key, token)]
            case .crashed:
                effects = [.conceal(key, token)]
            case .restoring:
                // The completion lands hidden and stays hidden.
                break
            case .unmounted, .mountedHidden, .hibernated:
                break
            }
            records[key] = record
            return effects

        case .mounted(let key, let token):
            guard var record = records[key], record.phase == .restoring, record.pending == token else { return [] }
            record.pending = nil
            let now = bump(&record)
            record.phase = record.wantsVisible ? .mountedVisible : .mountedHidden
            records[key] = record
            return [record.wantsVisible ? .reveal(key, now) : .conceal(key, now)]

        case .mountFailed(let key, let token):
            guard var record = records[key], record.phase == .restoring, record.pending == token else { return [] }
            record.pending = nil
            record.phase = record.restoresHibernated ? .hibernated : .unmounted
            _ = bump(&record)
            records[key] = record
            return []

        case .released(let key):
            guard var record = records[key] else { return [] }
            _ = bump(&record)
            record.pending = nil
            record.phase = .unmounted
            records[key] = record
            // A visible tab whose content went away is created again now.
            if record.wantsVisible { return send(.show(key)) }
            return []

        case .hibernate(let key):
            guard var record = records[key], record.phase == .mountedHidden, !record.wantsVisible else { return [] }
            let token = bump(&record)
            record.phase = .hibernated
            records[key] = record
            return [.release(key, token)]

        case .wake(let key):
            guard var record = records[key], record.phase == .hibernated else { return [] }
            let token = bump(&record)
            record.phase = .restoring
            record.pending = token
            record.restoresHibernated = true
            records[key] = record
            return [.restore(key, token)]

        case .crashed(let key):
            guard var record = records[key], record.phase != .hibernated else { return [] }
            _ = bump(&record)
            record.pending = nil
            record.phase = .crashed
            records[key] = record
            return []

        case .recovered(let key):
            guard var record = records[key], record.phase == .crashed else { return [] }
            let token = bump(&record)
            record.phase = record.wantsVisible ? .mountedVisible : .mountedHidden
            records[key] = record
            return [record.wantsVisible ? .reveal(key, token) : .conceal(key, token)]

        case .removed(let key):
            records[key] = nil
            return []
        }
    }

    private mutating func bump(_ record: inout Record) -> Token {
        nextGeneration += 1
        record.generation = nextGeneration
        return Token(nextGeneration)
    }
}
