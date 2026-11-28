import AppKit
import CmuxNextBrowser
import Foundation
import UiShellShootKit

// The UI shell's CmuxNextBrowser host: `cmux-ui-browser --shoot DIR [--scene browser-notice]`. It links CmuxNextBrowser and what it needs (CmuxNextUiBrowserModules), not the app
// composition root, so a change there rebuilds that module and this host's link; the leaf shell (cmux-ui-layer)
// never waits on it.

@main
@MainActor
struct UiBrowserHostMain {
    #if DEBUG
    /// The playground's owner outlives `open`: the shooter draws its window after the scene returns.
    static var playground: BrowserNoticeScenePlayground?
    #endif

    static func main() {
        UiShellShooter.runIfAsked { _ in scenes() }
        FileHandle.standardError.write(Data("usage: cmux-ui-browser --shoot DIR [--scene NAME,...]\n".utf8))
        exit(64)
    }

    static func scenes() -> [UiShellScene] {
        #if DEBUG
        [UiShellScene(name: "browser-notice", module: "CmuxNextBrowser") {
            let shown = playground ?? BrowserNoticeScenePlayground()
            playground = shown
            shown.show()
        }]
        #else
        []
        #endif
    }
}
