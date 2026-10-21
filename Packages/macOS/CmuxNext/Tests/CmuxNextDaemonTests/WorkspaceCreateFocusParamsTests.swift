import Foundation
import Testing
@testable import CmuxNextDaemon

/// `workspace.create` keeps the daemon's focus unless asked (agent evals,
/// new-workspace-background). The app asks for the person's own creations
/// (incognito window, debug showcase) so what they see stays the same, and
/// asks only a daemon that serves `workspace-create-focus-v1`: an older one
/// refuses the field and focuses every new workspace anyway.
struct WorkspaceCreateFocusParamsTests {
    @Test func focusIsSentToADaemonThatServesIt() {
        let params = StateResourceClient.workspaceCreateParams(
            name: nil, ephemeral: true, terminal: true, focus: true, daemonSupportsFocus: true)
        #expect(params == ["initial_content": .string("terminal"), "ephemeral": .bool(true), "focus": .bool(true)])
    }

    @Test func anOlderDaemonGetsNoFocusField() {
        let params = StateResourceClient.workspaceCreateParams(
            name: "showcase", ephemeral: false, terminal: false, focus: true, daemonSupportsFocus: false)
        #expect(params == ["initial_content": .string("empty"), "name": .string("showcase")])
    }

    @Test func aBackgroundCreationSendsNoFocus() {
        let params = StateResourceClient.workspaceCreateParams(
            name: nil, ephemeral: false, terminal: true, focus: false, daemonSupportsFocus: true)
        #expect(params["focus"] == nil)
    }
}
