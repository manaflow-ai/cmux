import AppKit
import CmuxNextMacScreen
import Foundation
import UiShellShootKit

/// The UI shell's CmuxNextMacScreen host (goal auto-ui-preview-under-60s): `cmux-ui-screen --shoot DIR [--scene NAME,...]` draws
/// CmuxNextMacScreen's scene into DIR from an incremental build of the module and what it needs, without the app.
@main @MainActor struct UiScreenHostMain {
    static func main() {
        UiShellShooter.runIfAsked { _ in scenes() }
        FileHandle.standardError.write(Data("usage: cmux-ui-screen --shoot DIR [--scene NAME,...]\n".utf8))
        exit(64)
    }

    static func scenes() -> [UiShellScene] {
        #if DEBUG
        [UiShellScene(name: "mac-screen-home", module: "CmuxNextMacScreen", keeping: MacScreenUiScene.show)]
        #else
        []
        #endif
    }
}
