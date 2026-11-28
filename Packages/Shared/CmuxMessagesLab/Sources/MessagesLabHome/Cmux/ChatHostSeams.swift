import AppKit
import CmuxAgentQuestion
import CmuxHomeRender

/// Where the vendored ChatController sends the user's changes in cmux. The
/// projection store is a mirror of HomeStore (the single writer), so a send
/// or a tapback is an intent, never a local transcript edit.
protocol ChatIntents: AnyObject {
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
    /// The owner can take a reply (MessagesLab's `.reply`: swipe-to-reply,
    /// Reply in the menu, "N Replies" opens the thread view); the reply is a
    /// send with the open thread's root.
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
    /// A link card was clicked (it opens too): a domain-only card may fetch its preview now.
    func linkTapped(_ ref: PartRef, url: String)
    /// My send can be cancelled (an upload, or a failed send): Cancel Upload.
    func canCancelSend(_ message: ID) -> Bool
    func cancelSend(_ message: ID)
    /// Open an attachment's bytes in the app the system picks (the context menu).
    func openAttachment(_ message: ID, _ attachment: ID)
    /// A click on a video bubble: play or pause it in place.
    func toggleVideo(_ ref: PartRef, _ attachment: ID)
    /// The inline playback state of a video part (the menu's Play or Pause).
    func videoState(_ ref: PartRef) -> HomeVideoState
    /// The transcript moved (user scroll, pin): paging and read cursor.
    func scrolled()
    /// The rows read a new window place (RowCell.windowPlace: the pane moved by a fraction of a point or
    /// resized) and may have moved their content onto other device pixels (RowCell.snapRow, MessagesLab
    /// c1457e5): what the host draws over a row follows it.
    func rowsPlaced()
    /// cmux-classic: an approval card's option (a click, Return or Esc on the card or in the empty
    /// field; `always`: "Always Allow", the owner saves the command's rule first). The answer goes to
    /// the owner; `completion(false)` when it was refused.
    func answerApproval(_ ref: PartRef, choice: String, always: Bool, completion: @escaping (Bool) -> Void)
    /// cmux-classic: the newest pending approval card in the transcript (the field's Return and Esc,
    /// its placeholder).
    func newestPendingApproval() -> (ref: PartRef, approval: ChiefRows.Approval)?
    /// cmux-classic: a question card's answer (QuestionCardRow). The answer goes to the owner;
    /// `completion(false)` when it was refused.
    func answerQuestion(_ ref: PartRef, answer: AgentQuestionAnswer, completion: @escaping (Bool) -> Void)
    /// cmux-classic: a Cloud result card's Open Workspace (ChiefCloudRows): the host opens the
    /// machine workspace as a local workspace (`cmux vm workspace open`).
    func openCloudWorkspace(machine: String, workspace: String)
    /// cmux-classic: a Cloud result card's Open Desktop: the host projects the machine's
    /// live display into cmux (`cmux vm desktop`) so the user can inspect or operate it.
    func openCloudDesktop(machine: String)
    /// cmux-classic: a Cloud result card's Stop Machine (ChiefCloudRows): the user asks the Chief to
    /// stop `machine` (`name` is how the card shows it); the Chief's `cmux vm pause` then asks with an
    /// approval card. `completion(false)` when the request was not sent.
    func stopCloudMachine(machine: String, name: String, completion: @escaping (Bool) -> Void)
    /// cmux-classic: a failed turn's Try Again (ChiefNoticeRows.swift): the owner runs the last
    /// message again; `completion(false)` when it did not (a turn runs, nothing to resend).
    func retryLastTurn(completion: @escaping (Bool) -> Void)
    /// cmux-classic: a saved note's Undo (ChiefNoticeRows.swift): the host forgets the note `fact`.
    func undoMemory(fact: String, completion: @escaping (Bool) -> Void)
}

extension ChatIntents {
    func answerApproval(_ ref: PartRef, choice: String, always: Bool, completion: @escaping (Bool) -> Void) { completion(false) }
    func newestPendingApproval() -> (ref: PartRef, approval: ChiefRows.Approval)? { nil }
    func answerQuestion(_ ref: PartRef, answer: AgentQuestionAnswer, completion: @escaping (Bool) -> Void) { completion(false) }
    func openCloudWorkspace(machine: String, workspace: String) {}
    func openCloudDesktop(machine: String) {}
    func stopCloudMachine(machine: String, name: String, completion: @escaping (Bool) -> Void) { completion(false) }
    func retryLastTurn(completion: @escaping (Bool) -> Void) { completion(false) }
    func undoMemory(fact: String, completion: @escaping (Bool) -> Void) { completion(false) }
}

/// One-shot wake-ups for the controller's engine clock (scheduled actions,
/// cleanups). CmuxNext passes its DemandTimer (the sanctioned wakeup
/// primitive, plans/cmux-next/idle-wakeups.md); no polling, no display link.
public protocol ChatWakeScheduler: AnyObject {
    /// Replaces any pending wake-up.
    func schedule(after seconds: Double, _ action: @escaping @MainActor @Sendable () -> Void)
    func cancel()
}
