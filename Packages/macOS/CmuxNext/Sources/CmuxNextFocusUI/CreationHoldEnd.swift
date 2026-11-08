/// Why a window's creation hold ended (R-L5: its end is a signal). `focusLanded`: every creation of the hold replied
/// and the focus it asked for holds, with a responder that takes the keys. `limitReached`: the hold's 2 s bound ended
/// it first, so the keys typed for the new terminal went on up to that late; logged, as a person feels it.
/// `focusLeft`: a key went to a field outside the content (a sidebar or bar field), which ends any hold. `windowClosed`.
/// `creationFailed`: a creation of the hold failed (the daemon refused it, or the connection ended); no focus landed.
public nonisolated enum CreationHoldEnd: Equatable, Sendable {
    case focusLanded, limitReached, focusLeft, windowClosed, creationFailed
}
