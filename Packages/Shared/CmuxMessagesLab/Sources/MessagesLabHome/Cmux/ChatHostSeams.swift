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
    /// The "+" button, a paste or a drop of an image. Lane 16 seam: the
    /// attachment intake (blob upload, chips, image bubble) lands there.
    func attach()
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
