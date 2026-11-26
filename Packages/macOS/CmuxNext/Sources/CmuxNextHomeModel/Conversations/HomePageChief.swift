public import CmuxHomeCore

/// What Home's Chief observation watches (TopHomePageView): the preferred Chief and whether this Mac's
/// Chief is the choice. The Engine row changes the choice while the preferred Chief stays nil (the cloud
/// read has not landed and this Mac's Chief is not listed yet), and the page must reconcile what it
/// opened by itself then too, so the choice is part of what it watches.
public struct HomePageChiefKey: Equatable, Sendable {
    public var chief: String?
    public var prefersLocal: Bool

    public init(chief: String?, prefersLocal: Bool) {
        self.chief = chief
        self.prefersLocal = prefersLocal
    }
}

/// What Home's page does when the preferred Chief changes, and which Chief it follows afterwards.
public struct HomePageChiefFollowUp: Equatable, Sendable {
    /// The conversation to open; nil: what is shown stays.
    public var open: ConversationID?
    /// The Chief conversation the page opened by itself, which a later Chief replaces. What the
    /// person picked themselves is never replaced, so it is not this.
    public var followed: String?

    public init(open: ConversationID?, followed: String?) {
        self.open = open
        self.followed = followed
    }
}
