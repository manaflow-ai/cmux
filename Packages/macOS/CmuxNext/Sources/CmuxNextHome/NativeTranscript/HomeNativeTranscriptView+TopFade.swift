import AppKit
import MessagesLabHome

extension HomeNativeTranscriptView {
    /// Debug Settings > Home > Top of the chat, live: every open chat with a header takes a new
    /// choice at once (MessagesLabHome `HomeTopFadeStyle`; Lawrence 2026-10-23).
    func followTopFadeStyle() {
        withObservationTracking {
            applyTopFadeStyle()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.followTopFadeStyle() }
        }
    }

    /// The chosen top fade, or no header's own fade (``HomeTunables/chatHeader`` off). Also from
    /// `applyTheme`, so the bands take a new theme's background.
    func applyTopFadeStyle() {
        let style = HomeTunables.topFadeStyle.value.style
        if showsHeader { transcript.setTopFadeStyle(style) } else { transcript.setBareTop() }
    }
}
