import AppKit
import CmuxNextMacScreen
import Foundation
import UiShellShootKit

// The UI shell's CmuxNextMacScreen host: `cmux-ui-macscreen --shoot DIR [--scene mac-screen-sharing]`. It links CmuxNextMacScreen and what it needs (CmuxNextUiMacScreenModules), not the app
// composition root, so a change there rebuilds that module and this host's link; the leaf shell (cmux-ui-layer)
// never waits on it.

@main
@MainActor
struct UiMacScreenHostMain {
    #if DEBUG
    /// The playground's owner outlives `open`: the shooter draws its window after the scene returns.
    static var playground: MacScreenScenePlayground?
    #endif

    static func main() {
        UiShellShooter.runIfAsked { _ in scenes() }
        FileHandle.standardError.write(Data("usage: cmux-ui-macscreen --shoot DIR [--scene NAME,...]\n".utf8))
        exit(64)
    }

    static func scenes() -> [UiShellScene] {
        #if DEBUG
        [UiShellScene(name: "mac-screen-sharing", module: "CmuxNextMacScreen") {
            let shown = playground ?? MacScreenScenePlayground()
            playground = shown
            shown.show()
        }]
        #else
        []
        #endif
    }
}
