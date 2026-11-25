import CmuxNextCloud
import Testing

/// A Cloud chat's Terminal and Browser open on its Cloud machine, never on this Mac (cmux#55413).
struct CloudChatToolRouteTests {
    @Test func aCloudChatsBrowserIsItsMachinesDesktopAndItsTerminalRunsThere() {
        // Shown in place in a Mac tab: the desktop beside it, a terminal on the machine.
        #expect(CloudChatToolRoute.resolve(.browser, onCloud: true, shownOnThisMac: true) == .desktopBeside)
        #expect(CloudChatToolRoute.resolve(.terminal, onCloud: true, shownOnThisMac: true) == .machineTerminal)
        // In its machine's workspace: the desktop in its own workspace; the pane's own split already runs there.
        #expect(CloudChatToolRoute.resolve(.browser, onCloud: true, shownOnThisMac: false) == .desktopWorkspace)
        #expect(CloudChatToolRoute.resolve(.terminal, onCloud: true, shownOnThisMac: false) == .asLocal)
    }

    @Test(arguments: [CloudChatToolRoute.Tool.browser, .terminal, .other], [true, false])
    func aLocalChatsToolsAreUnchanged(tool: CloudChatToolRoute.Tool, shown: Bool) {
        #expect(CloudChatToolRoute.resolve(tool, onCloud: false, shownOnThisMac: shown) == .asLocal)
    }
}
