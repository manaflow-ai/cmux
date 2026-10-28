import AppKit
import CmuxNextDesign
import CmuxNextWakeups

/// The settings a Home transcript follows live, read in one pass: the interface scale, Agent Chat
/// Zoom (`agentPane.zoom`; Cmd-= / Cmd-- / Cmd-0 on Home, `home.zoomIn`), Settings > Chief > Chief Chat >
/// Bubble Style, the Chief pet, and Debug Settings > Home's hero, top of the chat and mic button.
struct HomeTranscriptSettings: Equatable {
    /// The native first-run chrome's scale: the interface scale times the Chief chat's ``zoom``, so the
    /// empty chat's panel grows with the header and field around it.
    var textScale: CGFloat
    /// Agent Chat Zoom: the Chief chat is drawn at it, live, as an agent chat is.
    var zoom: CGFloat
    var bubblesThemed: Bool
    var chiefPet: Bool
    var hero: Bool
    var topFade: HomeTopFadeChoice
    var voiceInput: Bool

    /// The settings now (each read is tracked under a ``FrameObservation``).
    static func current() -> HomeTranscriptSettings {
        HomeTranscriptSettings(textScale: Typography.userScale * DesignSettings.shared.agentPaneZoom,
                               zoom: DesignSettings.shared.agentPaneZoom,
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

    /// A parked tab stays in its window with `isHidden` (`PaneContentView+Parking`). AppKit sends
    /// `viewDidHide`/`viewDidUnhide` to the descendants of a view whose `isHidden` changes, so an
    /// ancestor's hide reaches the node here (recipe R-hide: no ancestor walk).
    override public func viewDidHide() {
        super.viewDidHide()
        visibility.set(.hidden)
    }

    override public func viewDidUnhide() {
        super.viewDidUnhide()
        visibility.set(.visible)
    }

    /// The parent node is visible while the transcript is in a window and not stopped.
    func updateVisibility() {
        windowed.set(window != nil && !stopped ? .visible : .hidden)
    }

    /// Applies the settings that differ from the last ones applied (all of them the first time).
    func applySettings(_ settings: HomeTranscriptSettings) {
        let last = appliedSettings
        appliedSettings = settings
        if last?.voiceInput != settings.voiceInput { applyVoiceInput(settings.voiceInput) }
        if last?.textScale != settings.textScale { applyTextScale(settings.textScale) }
        if last?.zoom != settings.zoom {
            transcript.zoom = settings.zoom
            needsLayout = true // invalidate: the zoom changed the transcript's and the panel's metrics
        }
        bubbleStyle = settings.bubblesThemed ? .theme : .iMessage
        if last?.hero != settings.hero { firstRun.showsHero = settings.hero }
        // The first-run panel's pet row reads Show or Hide Chief Pet.
        if last?.chiefPet != settings.chiefPet { firstRun.setPetShown(settings.chiefPet) }
        if last?.topFade != settings.topFade { applyTopFadeStyle() }
    }
}
