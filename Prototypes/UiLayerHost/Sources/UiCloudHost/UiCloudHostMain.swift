import AppKit
import CmuxNextCloudUI
import Foundation
import UiShellShootKit

// The UI shell's CmuxNextCloudUI host: `cmux-ui-cloud --shoot DIR [--scene env-secrets]`. It links Cloud UI and what
// it needs (CmuxNextUiCloudModules), not the app composition root, so a Cloud UI change rebuilds that module and this
// host's link; the leaf shell (cmux-ui-layer) never waits on it.

@main
@MainActor
struct UiCloudHostMain {
    #if DEBUG
    /// The playground's owner outlives `open`: the shooter draws its window after the scene returns.
    static var envSecrets: EnvSecretsPlayground?
    #endif

    static func main() {
        UiShellShooter.runIfAsked { _ in scenes() }
        FileHandle.standardError.write(Data("usage: cmux-ui-cloud --shoot DIR [--scene NAME,...]\n".utf8))
        exit(64)
    }

    static func scenes() -> [UiShellScene] {
        #if DEBUG
        [UiShellScene(name: "env-secrets", module: "CmuxNextCloudUI") {
            let playground = envSecrets ?? EnvSecretsPlayground()
            envSecrets = playground
            playground.show(direction: 1, state: 2, dark: true)
        }]
        #else
        []
        #endif
    }
}
