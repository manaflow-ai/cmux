import AppKit
import CmuxNextSettingsWindow
import Foundation
import UiShellShootKit

// The UI shell's CmuxNextSettingsWindow host: `cmux-ui-settings --shoot DIR [--scene density-overlay]`. It links the
// Settings window module and what it needs (CmuxNextUiSettingsModules), not the app composition root, so a Settings
// window change rebuilds that module and this host's link; the leaf shell (cmux-ui-layer) never waits on it.

@main
@MainActor
struct UiSettingsHostMain {
    /// The playground's owner outlives `open`: the shooter draws its window after the scene returns.
    static var densityOverlay: DensityOverlayPlaygroundWindow?

    static func main() {
        UiShellShooter.runIfAsked { _ in scenes() }
        FileHandle.standardError.write(Data("usage: cmux-ui-settings --shoot DIR [--scene NAME,...]\n".utf8))
        exit(64)
    }

    static func scenes() -> [UiShellScene] {
        [UiShellScene(name: "density-overlay", module: "CmuxNextSettingsWindow") {
            let playground = densityOverlay ?? DensityOverlayPlaygroundWindow()
            densityOverlay = playground
            playground.show()
        }]
    }
}
