public import CmuxHomeCore
public import Foundation

/// Which intro still has to show on a Chief's empty conversation, and records the ones shown.
///
/// The intro is a fixed message from the Chief on its empty conversation, and it is contextual
/// (the user, 2026-10-27): the person's only Chief gives the ``ChiefIntroKind/welcome`` once per
/// install; a Chief made while other Chiefs exist asks what it should focus on
/// (``ChiefIntroKind/askFocus``), once per Chief. An intro is marked shown the moment it shows, so
/// it never returns, even when the person ignores it.
public struct ChiefIntroStore: Sendable {
    /// The UserDefaults key that records the welcome was shown (the once-per-install intro's key,
    /// so an install that saw it before never sees it again).
    static let shownKey = "home.firstRun.chiefIntroShown"
    /// The UserDefaults key of the Chief conversations that asked for their focus.
    static let askedKey = "home.firstRun.chiefIntroAsked"
    private let defaults: UserDefaults

    /// - Parameter defaults: The defaults the flags live in. The app passes `.standard`; tests pass a suite.
    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// Whether this install has not had its welcome yet (it shows on the only Chief's empty conversation).
    public var welcomePending: Bool { !defaults.bool(forKey: Self.shownKey) }

    /// The intro `conversation` shows now, or nil when it has nothing to show.
    /// - Parameters:
    ///   - conversation: The empty Chief conversation on screen.
    ///   - otherChiefs: How many other Chiefs the person has (listed, not archived).
    /// - Returns: The welcome for the only Chief (once per install), else the focus question (once per Chief).
    public func intro(for conversation: ConversationID, otherChiefs: Int) -> ChiefIntroKind? {
        if otherChiefs == 0 { return defaults.bool(forKey: Self.shownKey) ? nil : .welcome }
        return asked.contains(conversation.rawValue) ? nil : .askFocus
    }

    /// Records that `kind` showed on `conversation`, so it never shows there again.
    /// - Parameters:
    ///   - kind: The intro that showed.
    ///   - conversation: The Chief conversation it showed on.
    public func markShown(_ kind: ChiefIntroKind, for conversation: ConversationID) {
        switch kind {
        case .welcome:
            defaults.set(true, forKey: Self.shownKey)
        case .askFocus:
            defaults.set(asked.union([conversation.rawValue]).sorted(), forKey: Self.askedKey)
        }
    }

    private var asked: Set<String> { Set(defaults.stringArray(forKey: Self.askedKey) ?? []) }
}
