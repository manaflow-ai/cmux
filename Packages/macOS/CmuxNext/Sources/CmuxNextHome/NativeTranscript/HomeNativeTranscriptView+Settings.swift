import AppKit
import CmuxNextDesign
import CmuxNextWakeups

/// The settings a Home transcript follows live, read in one pass: the interface scale, Settings >
/// Chief > Chief Chat > Bubble Style, the Chief pet, and Debug Settings > Home's hero, top of the
/// chat and mic button.
struct HomeTranscriptSettings: Equatable {
    var textScale: CGFloat
    var bubblesThemed: Bool
    var chiefPet: Bool
    var hero: Bool
    var topFade: HomeTopFadeChoice
    var voiceInput: Bool

    /// The settings now (each read is tracked under a ``FrameObservation``).
    static func current() -> HomeTranscriptSettings {
        HomeTranscriptSettings(textScale: Typography.userScale,
                               bubblesThemed: DesignSettings.shared.homeChiefBubblesThemed,
                               chiefPet: DesignSettings.shared.homeChiefPetEnabled,
                               hero: HomeTunables.firstRunHero.value,
                               topFade: HomeTunables.topFadeStyle.value,
                               voiceInput: HomeTunables.voiceInput.value)
    }
}

extension HomeNativeTranscriptView {
    /// Follows ``HomeTranscriptSettings``: one observation for all of them, applied at most once a
    /// frame while the view is in a window, and once when it is back in one after a change (a
    /// hidden Home tab does no work for a setting). Blink coalesces style changes the same way: a
    /// change marks the frame, and the lifecycle runs once in the next BeginMainFrame
    /// (`PageAnimator::ScheduleVisualUpdate`, third_party/blink/renderer/core/page/page_animator.cc).
    func followSettings(on mainWork: MainWorkScheduler) -> FrameObservation<HomeTranscriptSettings> {
        let watch = FrameObservation(owner: "home.transcript.settings", delivery: .visible(visibility), on: mainWork) {
            HomeTranscriptSettings.current()
        } onChange: { [weak self] settings in
            self?.applySettings(settings)
        }
        applySettings(watch.value)
        return watch
    }

    override public func viewDidHide() {
        super.viewDidHide()
        updateVisibility()
    }

    override public func viewDidUnhide() {
        super.viewDidUnhide()
        updateVisibility()
    }

    /// The settings' node is visible while a person can see the transcript: in a window, neither it
    /// nor an ancestor hidden (a parked tab stays in its window with `isHidden`;
    /// `PaneContentView+Parking`), and not stopped. AppKit sends `viewDidHide`/`viewDidUnhide` to
    /// the descendants of a view whose `isHidden` changes, so an ancestor's hide reaches here.
    func updateVisibility() {
        visibility.set(window != nil && !isHiddenOrHasHiddenAncestor && !stopped ? .visible : .hidden)
    }

    /// Applies the settings that differ from the last ones applied (all of them the first time).
    func applySettings(_ settings: HomeTranscriptSettings) {
        let last = appliedSettings
        appliedSettings = settings
        if last?.voiceInput != settings.voiceInput { applyVoiceInput(settings.voiceInput) }
        if last?.textScale != settings.textScale { applyTextScale(settings.textScale) }
        bubbleStyle = settings.bubblesThemed ? .theme : .iMessage
        if last?.hero != settings.hero { firstRun.showsHero = settings.hero }
        // The first-run panel's pet row reads Show or Hide Chief Pet.
        if last?.chiefPet != settings.chiefPet { firstRun.setPetShown(settings.chiefPet) }
        if last?.topFade != settings.topFade { applyTopFadeStyle() }
    }
}
