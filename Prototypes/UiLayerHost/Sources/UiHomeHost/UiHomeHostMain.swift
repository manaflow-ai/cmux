import AppKit
import CmuxNextHomeEngine
import Foundation
import UiShellShootKit

// CmuxNextHomeEngine's scene host (cmux-ui-home --shoot DIR): its playground windows, linked against HomeEngine's
// closure only (CmuxNextUiHomeModules), never the app, so a HomeEngine save rebuilds HomeEngine and this file.

@main
@MainActor
struct UiHomeHostMain {
    static func main() {
        #if DEBUG
        UiShellShooter.runIfAsked { _ in
            [UiShellScene(name: "chief-teleport", module: "CmuxNextHomeEngine") { ChiefTeleportPlayground.show() }]
        }
        #endif
        FileHandle.standardError.write(Data("usage: cmux-ui-home --shoot DIR [--scene a,b] (a debug build)\n".utf8))
        exit(64)
    }
}
