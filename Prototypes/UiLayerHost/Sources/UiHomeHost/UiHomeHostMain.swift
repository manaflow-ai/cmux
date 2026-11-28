import AppKit
import CmuxNextHomeEngine
import Foundation
import UiShellShootKit

// The UI shell's CmuxNextHomeEngine host: `cmux-ui-home --shoot DIR [--scene chief-teleport]`. It links HomeEngine
// and what HomeEngine needs (CmuxNextUiHomeModules), not the app composition root, so a HomeEngine change rebuilds
// that module and this host's link; the leaf shell (cmux-ui-layer) never waits on it.

@main
@MainActor
struct UiHomeHostMain {
    static func main() {
        UiShellShooter.runIfAsked { _ in scenes() }
        FileHandle.standardError.write(Data("usage: cmux-ui-home --shoot DIR [--scene NAME,...]\n".utf8))
        exit(64)
    }

    static func scenes() -> [UiShellScene] {
        #if DEBUG
        [UiShellScene(name: "chief-teleport", module: "CmuxNextHomeEngine") { ChiefTeleportPlayground.show() }]
        #else
        []
        #endif
    }
}
