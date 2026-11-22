import Foundation
import Testing
@testable import CmuxNextApp
@testable import CmuxNextDaemon

/// The app-started Chief owner daemon reaches its brain for chief.engine.*
/// and chief.stop (cmux-tui forwards them to CMUX_TUI_CHIEF_TOOLS_SOCKET,
/// taken at daemon start). Without it they answered not_configured
/// (nxdog79-v2, 2026-10-09): only the CLI auto-start and install.sh set it.
@MainActor @Suite struct ChiefOwnerToolsSocketTests {
    @Test func theOwnerDaemonStartsWithThisHomesBrainToolsSocket() {
        let root = URL(fileURLWithPath: "/Users/someone/.cmux/chief/default", isDirectory: true)
        let env = ChiefConversationOwner.ownerEnvironment(home: ChiefHome(root: root, isolated: false),
                                                          process: ["HOME": "/Users/someone", "CMUX_TAG": "x"])
        #expect(env["CMUX_TUI_CHIEF_TOOLS_SOCKET"] == "/Users/someone/.cmux/chief/default/optchat/tools.sock")
        // server ensure keeps it and still drops a build's identity.
        let ensured = DaemonLauncher.chiefEnvironment(env)
        #expect(ensured["CMUX_TUI_CHIEF_TOOLS_SOCKET"] == "/Users/someone/.cmux/chief/default/optchat/tools.sock")
        #expect(ensured["CMUX_TAG"] == nil)
        #expect(ensured["HOME"] == "/Users/someone")
    }
}
