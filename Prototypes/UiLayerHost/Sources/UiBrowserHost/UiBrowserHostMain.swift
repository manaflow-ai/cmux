import AppKit
import CmuxNextBrowser
import Foundation
import UiShellShootKit

/// The UI shell's CmuxNextBrowser host (goal auto-ui-preview-under-60s): `cmux-ui-browser --shoot DIR [--scene NAME,...]` draws
/// CmuxNextBrowser's scene into DIR from an incremental build of the module and what it needs, without the app.
@main @MainActor struct UiBrowserHostMain {
    static func main() {
        UiShellShooter.runIfAsked { _ in scenes() }
        FileHandle.standardError.write(Data("usage: cmux-ui-browser --shoot DIR [--scene NAME,...]\n".utf8))
        exit(64)
    }

    static func scenes() -> [UiShellScene] {
        #if DEBUG
        [UiShellScene(name: "browser-chrome", module: "CmuxNextBrowser", keeping: BrowserUiScene.show)]
        #else
        []
        #endif
    }
}
