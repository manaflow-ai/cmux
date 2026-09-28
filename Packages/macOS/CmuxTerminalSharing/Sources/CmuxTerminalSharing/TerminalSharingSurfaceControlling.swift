import CmuxTerminalSizing

/// The host or relay behind one terminal, as the store's actions see it.
///
/// A local terminal's controller is the Mac host; a Cloud terminal's is its
/// mirror session, which forwards to the cmux-tui daemon. Each method returns
/// whether the request was accepted (applied locally or sent to the host).
@MainActor
public protocol TerminalSharingSurfaceControlling: AnyObject {
    /// Replaces the terminal's policy.
    func sharingSetPolicy(_ policy: TerminalSizingPolicy) -> Bool
    /// Sets or clears a participant's counts override.
    func sharingSetCountsOverride(participantID: String, value: Bool?) -> Bool
    /// Disconnects one participant (never this view itself).
    func sharingDisconnect(participantID: String) -> Bool
    /// Records explicit activity from this view.
    func sharingNoteSelfActivity()
    /// Reattaches this view after a `disconnected-by` detach.
    func sharingReattach(asViewer: Bool) -> Bool
}
