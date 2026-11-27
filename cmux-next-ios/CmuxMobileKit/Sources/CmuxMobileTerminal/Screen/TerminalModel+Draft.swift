#if os(iOS)
import Foundation

/// The composer's draft across a rebuilt terminal (Leo, 2026-11-21: "the connection f***ing
/// lagged ... and my drafted message on ios in the f***ing round composer got lost").
extension TerminalModel {
    /// What the tab's draft is on disk: the composer's text, or else a send made while the Mac
    /// was unreachable that has not reached it yet (it comes back if it never does).
    public var draftToKeep: String {
        composerText.isEmpty ? (heldComposerSend?.text ?? "") : composerText
    }

    /// This terminal replaces `previous` (the placeholder became the live session, or a
    /// reconnect rebuilt it): the draft and attachments come along. A send `previous` still
    /// held for an unreachable Mac never went (its session stops with it), so it comes back
    /// to the composer, said not sent, rather than vanish.
    public func adoptComposer(from previous: TerminalModel) {
        if composerText.isEmpty {
            if !previous.composerText.isEmpty {
                composerText = previous.composerText
            } else if let held = previous.heldComposerSend {
                composerText = held.text
                composerNotice = TerminalConnectionState.inputNotSentNotice
            }
        }
        if attachments.isEmpty { attachments = previous.attachments }
    }

    /// A cold start (or a host built with nothing before it): the tab's draft from disk.
    public func restoreDraft(_ text: String?) {
        guard composerText.isEmpty, let text, !text.isEmpty else { return }
        composerText = text
    }
}
#endif
