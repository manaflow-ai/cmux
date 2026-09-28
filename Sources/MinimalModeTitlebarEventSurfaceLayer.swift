import SwiftUI

struct MinimalModeTitlebarEventSurfaceLayer: View {
    let isFullScreen: Bool

    @WorkspaceTitlebarConfiguration private var titlebarSettings

    var body: some View {
        MinimalModeTitlebarEventSurfaceView(isEnabled: titlebarSettings.isMinimalMode && !isFullScreen)
    }
}
