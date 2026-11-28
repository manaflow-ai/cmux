import AppKit
import CmuxNextLayout
import Foundation
import UiShellShootKit

/// The UI shell's CmuxNextLayout host (goal auto-ui-preview-under-60s): `cmux-ui-layout --shoot DIR [--scene NAME,...]` draws
/// CmuxNextLayout's scene into DIR from an incremental build of the module and what it needs, without the app.
@main @MainActor struct UiLayoutHostMain {
    static func main() {
        UiShellShooter.runIfAsked { _ in scenes() }
        FileHandle.standardError.write(Data("usage: cmux-ui-layout --shoot DIR [--scene NAME,...]\n".utf8))
        exit(64)
    }

    static func scenes() -> [UiShellScene] {
        #if DEBUG
        [UiShellScene(name: "layout-columns", module: "CmuxNextLayout", keeping: LayoutUiScene.show)]
        #else
        []
        #endif
    }
}
