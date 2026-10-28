public import CmuxHomeCore
public import CoreGraphics

/// What a Home page shows that Home's store does not keep (`memoryDiscardInternalPages`): the shown
/// conversation and its open thread, the list's search and scroll, and the New Message page. Each
/// conversation's draft and transcript stay in the store. A Home tab or dock whose view was
/// discarded gives it to its next view, as Chrome gives a discarded tab's navigation entry its
/// scroll and form state back (content/public/browser/navigation_entry.h).
public struct HomePageViewState: Hashable, Sendable {
    /// What the person put on the New Message page: the To: field, and the blank page's text
    /// (a conversation the people already have keeps its own draft in the store).
    public struct NewMessage: Hashable, Sendable {
        public var recipients: HomeNewMessageDraft
        public var text: String

        public init(recipients: HomeNewMessageDraft, text: String) {
            self.recipients = recipients
            self.text = text
        }
    }

    public var shown: ConversationID?
    /// The message whose thread branch the transcript has open.
    public var thread: String?
    /// The list's search text.
    public var search: String
    /// Where the list was scrolled to.
    public var listScroll: CGPoint
    /// The New Message page's draft, nil when there is none or it is empty.
    public var newMessage: NewMessage?
    /// The New Message page is the one on screen.
    public var composing: Bool

    public init(shown: ConversationID? = nil, thread: String? = nil, search: String = "", listScroll: CGPoint = .zero,
                newMessage: NewMessage? = nil, composing: Bool = false) {
        self.shown = shown
        self.thread = thread
        self.search = search
        self.listScroll = listScroll
        self.newMessage = newMessage
        self.composing = composing
    }
}
