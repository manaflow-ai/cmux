import AppKit

/// Where the vendored ChatController sends the user's changes in cmux. The
/// projection store is a mirror of HomeStore (the single writer), so a send
/// or a tapback is an intent, never a local transcript edit.
protocol ChatIntents: AnyObject {
    /// Return in the field: send the draft (the adapter dispatches `.send` on
    /// the projection once the owner's log takes it, so the morph starts).
    func send()
    /// A tapback from the picker or the context menu.
    func react(_ ref: PartRef, _ kind: Reaction.Kind)
    /// Tapbacks are offered (false offline: H17).
    var canReact: Bool { get }
    /// The owner can take a reply (MessagesLab's `.reply`: swipe-to-reply,
    /// Reply in the menu). False until HomeOp has a reply operation.
    var canReply: Bool { get }
    /// The "+" button: the host's file picker.
    func pickAttachments()
    /// A paste in the field or a drop: true when the host's attachment
    /// intake took the pasteboard (files and pictures, Home's type rule).
    func takeAttachments(from pasteboard: NSPasteboard) -> Bool
    /// While dragging: whether a drop would be taken (types only).
    func acceptsAttachments(from pasteboard: NSPasteboard) -> Bool
    /// The field's text changed (the host clears its notice).
    func draftChanged()
    /// My send can be cancelled (an upload, or a failed send): Cancel Upload.
    func canCancelSend(_ message: ID) -> Bool
    func cancelSend(_ message: ID)
    /// A click on an attachment bubble: open its bytes.
    func openAttachment(_ message: ID, _ attachment: ID)
    /// The transcript moved (user scroll, pin): paging and read cursor.
    func scrolled()
}

/// One-shot wake-ups for the controller's engine clock (scheduled actions,
/// cleanups). CmuxNext passes its DemandTimer (the sanctioned wakeup
/// primitive, plans/cmux-next/idle-wakeups.md); no polling, no display link.
public protocol ChatWakeScheduler: AnyObject {
    /// Replaces any pending wake-up.
    func schedule(after seconds: Double, _ action: @escaping @MainActor @Sendable () -> Void)
    func cancel()
}
