import AppKit
import CmuxHomeRender

/// Where the vendored ChatController sends the user's changes in cmux. The
/// projection store is a mirror of HomeStore (the single writer), so a send
/// or a tapback is an intent, never a local transcript edit.
protocol ChatIntents: AnyObject {
    /// The user opened, drilled or closed a thread view (a permalink waiting for its message stops waiting).
    func threadMovedByUser()
    /// The message's permalink (`<scheme>://conversation/<c>/message/<m>`), nil when it has none yet.
    func messageLink(_ id: ID) -> String?
    /// Return in the field: send the draft (the adapter dispatches `.send` on
    /// the projection at once, so the morph starts, and gives the draft to
    /// HomeStore, which delivers it or queues it while offline).
    /// Nil when the draft went (or waits for the owner as "sending"), else
    /// why nothing was sent; the text then stays in the field.
    @discardableResult
    func send() -> String?
    /// A tapback from the picker or the context menu.
    func react(_ ref: PartRef, _ kind: Reaction.Kind)
    /// Tapbacks are offered (false offline: H17).
    var canReact: Bool { get }
    /// False for read-only run messages that have no conversation-message identity.
    func canInteract(with message: ID) -> Bool
    /// The owner can take a reply (MessagesLab's `.reply`: swipe-to-reply,
    /// Reply in the menu, "N Replies" opens the thread view); the reply is a
    /// send with the open thread's root.
    var canReply: Bool { get }
    /// The "+" button: the host's file picker.
    func pickAttachments()
    /// A paste in the field or a drop: true when the host's attachment
    /// intake took the pasteboard (files and pictures, Home's type rule).
    func takeAttachments(from pasteboard: NSPasteboard) -> Bool
    /// Whether a paste would be taken (types only).
    func acceptsAttachments(from pasteboard: NSPasteboard) -> Bool
    /// The words a paste the intake took carries beside its attachments (a note's text around
    /// its pictures; the box's own copy of text and a picture); nil when none.
    func attachmentPasteText(from pasteboard: NSPasteboard) -> String?
    /// The file of the draft attachment `id`, named like it; nil when it has none here.
    func draftAttachmentFile(_ id: ID) -> URL?
    /// A drop on the field: true when the host's intake took the drag's
    /// pasteboard (file URLs, file promises, pictures).
    func takeDroppedAttachments(from pasteboard: NSPasteboard) -> Bool
    /// While dragging over the field: whether a drop would be taken (types only).
    func acceptsDroppedAttachments(from pasteboard: NSPasteboard) -> Bool
    /// The field became or stopped being the target of a drag the host takes.
    func attachmentDropTargeted(_ targeted: Bool)
    /// A click on the status line (the Chief's "working on" line): `rect` is its text in `view`'s
    /// coordinates, where the turn's details open.
    func statusLineClicked(_ rect: CGRect, in view: NSView)
    /// The field's text changed (the host clears its notice).
    func draftChanged()
    /// A link card was clicked (it opens too): a domain-only card may fetch its preview now.
    func linkTapped(_ ref: PartRef, url: String)
    /// My send can be cancelled (an upload, or a failed send): Cancel Upload.
    func canCancelSend(_ message: ID) -> Bool
    func cancelSend(_ message: ID)
    /// My send is "Not Delivered": Try Again and Delete are offered.
    func canRetrySend(_ message: ID) -> Bool
    /// Try Again: the send goes again (`HomeStore.retry`).
    func retrySend(_ message: ID)
    /// A committed person message in a Chief conversation can ask the Chief
    /// to answer that message again. This is separate from `retrySend`, which
    /// resends a failed local upload.
    func canRetryChiefTurn(_ message: ID) -> Bool
    func retryChiefTurn(_ message: ID)
    /// Delete: the failed send goes (`HomeStore.discardFailed`).
    func deleteFailedSend(_ message: ID)
    /// Forward… is offered (the host routes a bubble's text to another chat).
    var canForward: Bool { get }
    /// Forward…: the bubble's text goes to another chat or agent the host asks for.
    func forward(_ text: String)
    /// Open an attachment's bytes: in the host (``HomeFileHost``, cmux shows it on the right of
    /// the chat), else in the app the system picks.
    func openAttachment(_ message: ID, _ attachment: ID)
    /// The attachment's local copy, named like the attachment (fetched when needed); nil when it
    /// cannot be read here. The host's menu rows (Open With, Reveal) run on it.
    func attachmentFile(_ message: ID, _ attachment: ID) async -> URL?
    /// A click on a video bubble: play or pause it in place.
    func toggleVideo(_ ref: PartRef, _ attachment: ID)
    /// The inline playback state of a video part (the menu's Play or Pause).
    func videoState(_ ref: PartRef) -> HomeVideoState
    /// A double-click on a video bubble, its expand button or View Larger: the video opens in
    /// the large viewer over the pane (the user, 2026-10-30), from where the bubble was.
    func openVideo(_ ref: PartRef, _ attachment: ID)
    /// A click on an agent-message fold's row: its messages show in full, or fold again.
    func toggleAgentMessages(_ group: String)
    /// A click on the row of message `message`: an agent-message fold or notes row opens or closes
    /// (true); false for every other row, which keeps its own click.
    func agentRowClicked(_ message: ID) -> Bool
    /// The transcript moved (user scroll, pin): paging and read cursor.
    func scrolled()
    /// The rows read a new window place (RowCell.windowPlace: the pane moved by a fraction of a point or
    /// resized) and may have moved their content onto other device pixels (RowCell.snapRow, MessagesLab
    /// c1457e5): what the host draws over a row follows it.
    func rowsPlaced()
}

extension ChatIntents {
    func canInteract(with message: ID) -> Bool { true }
    /// Hosts without agent messages have no folds.
    func toggleAgentMessages(_ group: String) {}
    func agentRowClicked(_ message: ID) -> Bool { false }
    /// Hosts without a large viewer play the video in its bubble.
    func openVideo(_ ref: PartRef, _ attachment: ID) {}
    /// No Forward… unless the host routes it (test hosts, the New Message composer).
    var canForward: Bool { false }
    func forward(_ text: String) {}
    /// Hosts without a Chief control path do not expose turn retry.
    func canRetryChiefTurn(_ message: ID) -> Bool { false }
    func retryChiefTurn(_ message: ID) {}
}

/// One-shot wake-ups for the controller's engine clock (scheduled actions,
/// cleanups). CmuxNext passes its DemandTimer (the sanctioned wakeup
/// primitive, plans/cmux-next/idle-wakeups.md); no polling, no display link.
public protocol ChatWakeScheduler: AnyObject {
    /// Replaces any pending wake-up.
    func schedule(after seconds: Double, _ action: @escaping @MainActor @Sendable () -> Void)
    func cancel()
}

extension ChatIntents {
    /// No local copy (hosts and fakes without attachment bytes).
    func attachmentFile(_ message: ID, _ attachment: ID) async -> URL? { nil }
    /// Hosts without a drop intake of their own take a drop as a paste.
    func takeDroppedAttachments(from pasteboard: NSPasteboard) -> Bool { takeAttachments(from: pasteboard) }
    func acceptsDroppedAttachments(from pasteboard: NSPasteboard) -> Bool { acceptsAttachments(from: pasteboard) }
    func attachmentDropTargeted(_ targeted: Bool) {}
    func attachmentPasteText(from pasteboard: NSPasteboard) -> String? { nil }
    func draftAttachmentFile(_ id: ID) -> URL? { nil }
}
