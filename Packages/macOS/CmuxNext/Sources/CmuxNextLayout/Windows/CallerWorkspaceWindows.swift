public import Observation

/// The window the person last prompted the Chief from (#32989): the window whose Home
/// transcript sent the message. A Chief turn's caller is the Home chat (`caller.home_chat`),
/// and the app does not know a turn's session, so this is where that turn is: its
/// `system.identify` names this window's Home, and the workspaces it creates without
/// naming a window open here. Nil until a message is sent, once its window closed, or once
/// the person's next message to the Chief came from elsewhere (a phone, another Mac, the New
/// Message sheet, an action): no window prompted that turn, and its workspaces go to the most
/// recent window, as before. One value for the app: the latest prompt from this Mac wins.
@Observable
public final class ChiefPromptWindow {
    /// The prompting window's id (`WindowState.id`).
    public private(set) var id: String?
    /// The person's newest messages to the Chief that the store showed (their ids; nil until the
    /// first read), and whether a send from a window's Home transcript is still to show there.
    @ObservationIgnored private var seenPersonMessages: Set<String>?
    @ObservationIgnored private var awaitsWindowSend = false

    public init() {}

    /// Window `id`'s Home transcript sent a message to the Chief.
    public func note(_ id: String) {
        if self.id != id { self.id = id }
        awaitsWindowSend = true
    }

    /// The newest message from the person in each Chief conversation (their ids). A new one that a
    /// window's send made keeps that window; any other new one came from elsewhere and clears it.
    /// The first read (at launch) only sets the baseline.
    public func personMessages(_ ids: Set<String>) {
        guard ids != seenPersonMessages else { return }
        let previous = seenPersonMessages
        seenPersonMessages = ids
        guard previous != nil || awaitsWindowSend, !ids.subtracting(previous ?? []).isEmpty else { return }
        if awaitsWindowSend {
            awaitsWindowSend = false
        } else if id != nil {
            id = nil
        }
    }

    /// The prompting window while it is still open.
    public func open(in registry: WindowRegistry) -> String? {
        guard let id, registry.window(id)?.isOpen == true else { return nil }
        return id
    }
}

/// New workspaces the CLI told the app about before creating them (`workspace.expect_window`,
/// #32989): the create's idempotency key, which the daemon echoes as the workspace-added
/// delta's `mutation_id`, names the window it opens in. The claim is made when the delta
/// arrives (`DaemonStore.onResourceWorkspaceAdded`), before membership reconciles it, so the
/// workspace never shows in another window first.
public struct ExpectedWorkspaceWindows: Sendable {
    /// The bound: a create that never came (refused, another session's) leaves its entry,
    /// and the oldest goes first.
    public static let limit = 64

    /// Where one announced create opens: `window`, selected there only when `shows`
    /// (`workspace create --focus`); otherwise filed without changing what the window shows.
    public struct Expected: Equatable, Sendable {
        public var window: String
        public var shows: Bool

        public init(window: String, shows: Bool) {
            self.window = window
            self.shows = shows
        }
    }

    public private(set) var entries: [String: Expected] = [:]
    private var order: [String] = []

    public init() {}

    public mutating func expect(key: String, window: String, shows: Bool) {
        if entries.updateValue(Expected(window: window, shows: shows), forKey: key) == nil { order.append(key) }
        while order.count > Self.limit { entries[order.removeFirst()] = nil }
    }

    /// Where `key`'s create opens, taken: one create, one placement.
    public mutating func take(_ key: String) -> Expected? {
        guard let expected = entries.removeValue(forKey: key) else { return nil }
        order.removeAll { $0 == key }
        return expected
    }
}

extension WorkspaceClaims {
    /// Files new workspace `id`, which a caller's create is about to make or just made, into `window`
    /// (a control caller's own window) once the daemon reports it: quietly unless `shows`, and never
    /// for a window that is not open or a workspace already placed or claimed. Returns whether it
    /// claimed it; false leaves the create to reconcile (the most recent window).
    public mutating func claimForCaller(_ id: String, window: String?, shows: Bool = false, in registry: WindowRegistry) -> Bool {
        guard let window, registry.window(window)?.isOpen == true,
              registry.owner(of: id) == nil, pending[id] == nil else { return false }
        pending[id] = window
        background.insert(id)
        if !shows { quiet.insert(id) }
        return true
    }

    /// A CLI create announced by `workspace.expect_window` arrived as workspace `id`: it opens in
    /// the window it named (#32989), never in the most recent one.
    @discardableResult
    public mutating func claimExpected(_ id: String, key: String, in registry: WindowRegistry) -> Bool {
        guard let expected = expected.take(key) else { return false }
        return claimForCaller(id, window: expected.window, shows: expected.shows, in: registry)
    }
}
