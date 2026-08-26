import CmuxAppKitSupportUI
import CmuxSettings
import CmuxSettingsUI
import SwiftUI

/// Window-root backdrop fill that composes with the dynamic video background.
///
/// When no video is playing in this window this renders the standard
/// ``WindowBackdropLayer`` unchanged. While the window's
/// ``VideoBackgroundPresentation`` reports an installed player, the
/// window-root terminal fill is drawn at the configured dim opacity instead
/// of the terminal background opacity, so the video installed below the
/// content view shows through while terminal text stays readable. The
/// existing `background-opacity` handling still wins when it is more
/// transparent than the dim.
///
/// The decision keys off the controller's authoritative playback state, not
/// the raw settings: a failed embed removes the player and the fill returns
/// to normal instead of dimming over nothing.
struct VideoAwareWindowRootBackdrop: View {
    let snapshot: WindowAppearanceSnapshot
    let presentation: VideoBackgroundPresentation?

    @LiveSetting(\.terminal.videoBackgroundDimOpacity) private var videoBackgroundDimOpacity

    var body: some View {
        if presentation?.isActive == true,
           case let .ghosttyTerminalBackdrop(color, opacity, _) = snapshot.terminalBackdropPolicy() {
            let dim = CGFloat(VideoBackgroundSettings().normalizedDimOpacity(videoBackgroundDimOpacity))
            Color(nsColor: color.withAlphaComponent(min(opacity, dim)))
        } else {
            WindowBackdropLayer(role: .windowRoot, snapshot: snapshot)
        }
    }
}
