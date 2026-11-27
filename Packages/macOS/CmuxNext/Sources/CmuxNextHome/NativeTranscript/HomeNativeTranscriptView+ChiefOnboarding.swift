public import AppKit

/// Meet Chief (``HomeChiefOnboardingCard``) on the empty Chief chat: the host shows the state of the app's
/// ``ChiefOnboarding`` here and runs the clicks it reports (``onChiefOnboarding``). While it shows it takes the
/// first-run panel's place, centred between the header (and anything pinned under it) and the message box.
extension HomeNativeTranscriptView {
    /// Shows Meet Chief at `state`, or removes it (nil). The card rises in the first time it shows; a new step
    /// changes its content in place.
    /// - Parameter state: What the card shows, nil for no card.
    public func showChiefOnboarding(_ state: HomeChiefOnboardingState?) {
        let appearing = chiefOnboarding.state == nil && state != nil
        if let state {
            chiefOnboarding.apply(state)
        } else if chiefOnboarding.state != nil {
            chiefOnboarding.clear()
        }
        chiefOnboarding.isHidden = state == nil
        updateFirstRun()
        needsLayout = true
        if appearing { chiefOnboarding.animateIn() }
    }

    /// A click on the card: the host runs it; Start chatting also puts the keyboard in the message box.
    func chiefOnboardingClicked(_ action: HomeChiefOnboardingAction) {
        let starts = action == .next && chiefOnboarding.state?.isLast == true
        onChiefOnboarding(action)
        if starts { transcript.focusPrimaryInputForTyping() }
    }

    /// Centres the card in `panel` (the first-run panel's frame), no wider than its column; a pane too short for
    /// it keeps its top under the header and lets the rest go under the message box's edge.
    func layoutChiefOnboarding(in panel: CGRect) {
        guard !chiefOnboarding.isHidden else { return }
        let scale = chiefOnboarding.scale
        let width = max(0, min(HomeChiefOnboardingCard.maxWidth * scale, panel.width - 48 * scale)).rounded()
        let height = chiefOnboarding.height(for: width)
        let y = panel.minY + max(0, (panel.height - height) / 2)
        let frame = CGRect(x: ((panel.width - width) / 2).rounded(), y: y.rounded(), width: width, height: height)
        if chiefOnboarding.frame != frame { chiefOnboarding.frame = frame }
    }

    #if DEBUG || CMUX_BENCH_HOOKS
    /// Meet Chief is on screen (capture scenes settle on it).
    public var debugChiefOnboardingShown: Bool {
        !chiefOnboarding.isHiddenOrHasHiddenAncestor && chiefOnboarding.window != nil && chiefOnboarding.frame.height > 0
    }
    /// The state Meet Chief shows, nil for none.
    public var debugChiefOnboardingState: HomeChiefOnboardingState? { chiefOnboarding.state }
    #endif
}
