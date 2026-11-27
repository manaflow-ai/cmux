import AppKit
import CmuxNextApp
import Foundation
import UiShellShootKit

// The UI shell's CmuxNextApp host: `cmux-ui-app --shoot DIR [--scene density-playground]`. It links the app library
// (CmuxNextApp) and draws the App's own windows from AppUiShellScenes, so a CmuxNextApp change rebuilds that module
// and this host's link, about 31 s warm; the leaf shell (cmux-ui-layer) never waits on it.

@main
@MainActor
struct UiAppHostMain {
    static func main() {
        UiShellShooter.runIfAsked { _ in scenes() }
        FileHandle.standardError.write(Data("usage: cmux-ui-app --shoot DIR [--scene NAME,...]\n".utf8))
        exit(64)
    }

    static func scenes() -> [UiShellScene] {
        #if DEBUG
        let density = AppUiShellScenes.densityPlayground()
        return [UiShellScene(name: "density-playground", module: "CmuxNextApp") { density() }]
        #else
        return []
        #endif
    }
}
