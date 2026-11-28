import AppKit
import CmuxNextAgentPane
import Foundation
import UiShellShootKit

/// The UI shell's CmuxNextAgentPane host (goal auto-ui-preview-under-60s): `cmux-ui-agentpane --shoot DIR [--scene NAME,...]` draws
/// CmuxNextAgentPane's scene into DIR from an incremental build of the module and what it needs, without the app.
@main @MainActor struct UiAgentPaneHostMain {
    static func main() {
        UiShellShooter.runIfAsked { _ in scenes() }
        FileHandle.standardError.write(Data("usage: cmux-ui-agentpane --shoot DIR [--scene NAME,...]\n".utf8))
        exit(64)
    }

    static func scenes() -> [UiShellScene] {
        #if DEBUG
        [UiShellScene(name: "agentpane-native", module: "CmuxNextAgentPane") { AgentPaneUiScene.show() }]
        #else
        []
        #endif
    }
}
