import CmuxAppKitSupportUI
import SwiftUI

/// The bottom of a main window: the background image, when one is set, under
/// the terminal-colored root backdrop. Both fill the window, titlebar
/// included, and never take clicks.
struct WindowRootBackdropView: View {
    let snapshot: WindowAppearanceSnapshot

    var body: some View {
        ZStack {
            WindowBackgroundImageLayer(
                snapshot: snapshot,
                homeDirectory: FileManager.default.homeDirectoryForCurrentUser
            )
            WindowBackdropLayer(role: .windowRoot, snapshot: snapshot)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}
