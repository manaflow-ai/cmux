import SwiftUI

struct SidebarMediaActivityIndicators: View {
    let mediaActivity: BrowserMediaActivity
    let symbolPointSize: CGFloat
    let audioColor: Color

    var body: some View {
        if mediaActivity.isPlayingAudio {
            let audioPlayingTooltip = String(
                localized: "sidebar.mediaActivity.audio.tooltip",
                defaultValue: "Playing audio"
            )
            CmuxSystemSymbolImage(magnified: "speaker.wave.2.fill", pointSize: symbolPointSize, weight: .semibold)
                .foregroundColor(audioColor)
                .safeHelp(audioPlayingTooltip)
                .accessibilityLabel(audioPlayingTooltip)
        }

        if mediaActivity.isUsingMicrophone {
            let microphoneInUseTooltip = String(
                localized: "sidebar.mediaActivity.microphone.tooltip",
                defaultValue: "Microphone in use"
            )
            CmuxSystemSymbolImage(magnified: "mic.fill", pointSize: symbolPointSize, weight: .semibold)
                .foregroundColor(.orange)
                .safeHelp(microphoneInUseTooltip)
                .accessibilityLabel(microphoneInUseTooltip)
        }

        if mediaActivity.isUsingCamera {
            let cameraInUseTooltip = String(
                localized: "sidebar.mediaActivity.camera.tooltip",
                defaultValue: "Camera in use"
            )
            CmuxSystemSymbolImage(magnified: "video.fill", pointSize: symbolPointSize, weight: .semibold)
                .foregroundColor(.green)
                .safeHelp(cameraInUseTooltip)
                .accessibilityLabel(cameraInUseTooltip)
        }
    }
}
