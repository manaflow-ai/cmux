import CmuxNextWakeups

/// A switched-to workspace's rings wait for the frame that shows it (cmux#46908, cmux#59901). They sit on the window's
/// overlay plane, above the content and its page windows, so hiding the content never hides them: while the window keeps
/// the outgoing workspace on screen for this one's unpainted pages (`PanePaintHold`, up to 500 ms), a ring let go draws on
/// the old workspace's picture. The App holds them as the switch begins and lets them go once the window shows this one.
extension LayoutRootView {
    /// The window is about to show this layout: its rings draw nothing until ``releaseHeldAttention(after:)``.
    public func holdAttention() {
        model.attentionHold &+= 1
        model.holdsAttentionUntilShown = true
    }

    /// This layout left the screen: a release still waiting for it does nothing.
    public func dropAttentionHold() {
        model.attentionHold &+= 1
        model.holdsAttentionUntilShown = false
    }

    /// The window put this layout up. `shown` runs its body once the window shows it, and says false when it shows now.
    /// The rings draw after that frame committed, where a read one blinks out (cmux#56125).
    public func releaseHeldAttention(after shown: (@escaping () -> Void) -> Bool) {
        let hold = model.attentionHold
        let release = {
            AfterFrameCommit().run { [weak self] in
                guard let self, model.attentionHold == hold, model.holdsAttentionUntilShown else { return }
                model.holdsAttentionUntilShown = false
                syncWithModel()
            }
        }
        if !shown(release) { release() }
    }
}
