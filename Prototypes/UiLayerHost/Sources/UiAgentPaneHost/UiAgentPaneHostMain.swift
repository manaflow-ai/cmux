import AppKit
import CmuxNextAgentPane
import Foundation
import UiShellShootKit

// The UI shell's CmuxNextAgentPane host: `cmux-ui-agentpane --shoot DIR [--scene agent-new-tab]`. It links CmuxNextAgentPane and what it needs (CmuxNextUiAgentPaneModules), not the app
// composition root, so a change there rebuilds that module and this host's link; the leaf shell (cmux-ui-layer)
// never waits on it.

@main
@MainActor
struct UiAgentPaneHostMain {
    #if DEBUG
    /// The playground's owner outlives `open`: the shooter draws its window after the scene returns.
    static var playground: NativeNewTabScenePlayground?
    #endif

    static func main() {
        UiShellShooter.runIfAsked { _ in scenes() }
        FileHandle.standardError.write(Data("usage: cmux-ui-agentpane --shoot DIR [--scene NAME,...]\n".utf8))
        exit(64)
    }

    static func scenes() -> [UiShellScene] {
        #if DEBUG
        [UiShellScene(name: "agent-new-tab", module: "CmuxNextAgentPane") {
            let shown = playground ?? NativeNewTabScenePlayground()
            playground = shown
            shown.show()
        }]
        #else
        []
        #endif
    }
}
