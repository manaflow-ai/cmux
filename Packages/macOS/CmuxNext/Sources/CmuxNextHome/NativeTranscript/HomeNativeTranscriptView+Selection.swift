import AppKit

extension HomeNativeTranscriptView {
    /// The open thread's root message id (MessagesLab's `ui.openThread`), nil when no thread is
    /// open (the DEBUG socket's `open_thread`).
    public var openThreadRoot: String? { transcript.debugOpenThread }

    /// The owner's id of the message the open thread view shows (a nested thread's drilled branch,
    /// else its root): the message part of the docked Home's selection hand-off (Messages ->
    /// Channels opens `#/conversation/<id>/message/<message>`). nil when no thread is open.
    public var openThreadMessage: String? { transcript.openThreadMessage }

    /// Opens a permalink's message (`#/conversation/<id>/message/<message>`): its thread at its
    /// branch, any depth, once the transcript holds it.
    public func reveal(message: String) { transcript.reveal(message: message) }

    /// Reply to Selection (`home.replyToSelection`, Cmd-Shift-R): the text selected in one message
    /// becomes the reply's quote, as the message menu's item does. False: no such selection.
    public func replyToSelection() -> Bool { transcript.replyToSelection() }

    /// The build's link scheme, for "Copy Link" in the message menu.
    public var linkScheme: String? {
        get { transcript.linkScheme }
        set { transcript.linkScheme = newValue }
    }

    /// Automation (DEBUG socket): thread view header check and Copy Link drives (MessagesLabHomeView.debugTreeDrive).
    public func debugTreeDrive(_ action: String, _ args: [String: String]) -> [String: String]? { transcript.debugTreeDrive(action, args) }

    /// Automation (DEBUG socket): the open drill path, root first, as owner ids.
    public var debugOpenThreadPath: [String] { transcript.debugOpenThreadPath }

    /// Automation (DEBUG socket): a click on "N Replies" under the message `text` in the open
    /// thread view (a drill-in); the drill path after it, nil when no such label shows.
    public func debugOpenBranch(text: String) -> [String]? { transcript.debugOpenBranch(text: text) }

    /// Automation (DEBUG socket): Reply… on the shown bubble whose text is `text`; the drill path after it.
    public func debugReply(text: String) -> [String]? { transcript.debugReply(text: text) }
}
