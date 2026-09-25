import SwiftUI

struct WorkspaceTitlebarModeLayer<Titlebar: View, CompactControls: View>: View {
    let titlebar: () -> Titlebar
    @ViewBuilder var compactControls: () -> CompactControls

    @WorkspaceTitlebarConfiguration private var titlebarSettings

    var body: some View {
        if !titlebarSettings.isHidden {
            titlebar()
        } else if !titlebarSettings.isMinimalMode {
            compactControls()
        }
    }
}
