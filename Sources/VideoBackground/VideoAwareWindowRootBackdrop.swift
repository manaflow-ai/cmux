import CmuxAppKitSupportUI
import CmuxBrowser
import CmuxSettings
import CmuxSettingsUI
import SwiftUI

/// Window-root backdrop fill that composes with the dynamic video background.
///
/// When the video background is off this renders the standard
/// ``WindowBackdropLayer`` unchanged. When a video source is active, the
/// window-root terminal fill is drawn at the configured dim opacity instead
/// of the terminal background opacity, so the video installed below the
/// content view shows through while terminal text stays readable. The
/// existing `background-opacity` handling still wins when it is more
/// transparent than the dim.
struct VideoAwareWindowRootBackdrop: View {
    let snapshot: WindowAppearanceSnapshot

    @LiveSetting(\.terminal.videoBackgroundEnabled) private var videoBackgroundEnabled
    @LiveSetting(\.terminal.videoBackgroundSource) private var videoBackgroundSource
    @LiveSetting(\.terminal.videoBackgroundDimOpacity) private var videoBackgroundDimOpacity

    var body: some View {
        if videoBackgroundEnabled,
           VideoBackgroundSource.parse(videoBackgroundSource) != nil,
           case let .ghosttyTerminalBackdrop(color, opacity, _) = snapshot.terminalBackdropPolicy() {
            let dim = CGFloat(VideoBackgroundSettings().normalizedDimOpacity(videoBackgroundDimOpacity))
            Color(nsColor: color.withAlphaComponent(min(opacity, dim)))
        } else {
            WindowBackdropLayer(role: .windowRoot, snapshot: snapshot)
        }
    }
}
