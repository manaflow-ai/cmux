import CmuxNextControl

/// Red-commit stub (the next commit implements it) with the base behavior: a page's CEF tab is
/// made at once, in the turn that asked for it. Only the tests make it; the host does not use it yet.
@MainActor
final class ChromiumPageFrameBudget {
    init(frames: any ControlFrameSource) {}

    /// Pages waiting for their frame: none, every start goes at once.
    var waitingCount: Int { 0 }

    /// Returns at once.
    func nextFrame() async {}
}
