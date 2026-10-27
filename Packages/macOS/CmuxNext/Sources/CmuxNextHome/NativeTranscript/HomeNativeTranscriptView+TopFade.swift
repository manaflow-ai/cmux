import AppKit
import MessagesLabHome

extension HomeNativeTranscriptView {
    /// The chosen top fade, or no header's own fade (``HomeTunables/chatHeader`` off). From
    /// Debug Settings > Home > Top of the chat, live (`followSettings(on:)`: every open chat with a
    /// header takes a new choice; MessagesLabHome `HomeTopFadeStyle`, Lawrence 2026-10-23), and from
    /// `applyTheme`, so the bands take a new theme's background.
    func applyTopFadeStyle() {
        let style = HomeTunables.topFadeStyle.value.style
        if showsHeader { transcript.setTopFadeStyle(style) } else { transcript.setBareTop() }
    }
}
