import CmuxNextIPC
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
        let request = StateResourceClient.workspaceCreateRequest(
            name: nil, ephemeral: true, terminal: true, focus: true, daemonSupportsFocus: true)
        #expect(request == V2WorkspaceCreateRequest(ephemeral: true, focus: true, initialContent: .terminal))
    }

    @Test func anOlderDaemonGetsNoFocusField() {
        let request = StateResourceClient.workspaceCreateRequest(
            name: "showcase", ephemeral: false, terminal: false, focus: true, daemonSupportsFocus: false)
        #expect(request == V2WorkspaceCreateRequest(initialContent: .empty, name: "showcase"))
    }

    @Test func aBackgroundCreationSendsNoFocus() {
        let request = StateResourceClient.workspaceCreateRequest(
            name: nil, ephemeral: false, terminal: true, focus: false, daemonSupportsFocus: true)
        #expect(request.focus == nil)
    }
}
