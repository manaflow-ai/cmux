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

/// One rule decides which Cloud chat a person's new terminal or browser goes to (cmux#57249).
struct CloudChatFocusTests {
    @Test func aMacTabShowingACloudChatSendsItsToolsToThatChatsMachine() {
        let mac = CloudChatFocus.Shown(machine: "mac", key: "mac-1", fronts: ("vm-1", "chat-1"), onCloud: false, isChat: true)
        #expect(CloudChatFocus.resolve(byPerson: true, namesPlace: false, shown: mac) == .cloudChat(machine: "vm-1", key: "chat-1"))
    }

    @Test func aCloudMachinesOwnChatSendsItsToolsThere() {
        let chat = CloudChatFocus.Shown(machine: "vm-1", key: "chat-1", onCloud: true, isChat: true)
        #expect(CloudChatFocus.resolve(byPerson: true, namesPlace: false, shown: chat) == .cloudChat(machine: "vm-1", key: "chat-1"))
    }

    @Test func otherTabsScriptsAndPlacedOpensAreUnchanged() {
        let localChat = CloudChatFocus.Shown(machine: "mac", key: "c", onCloud: false, isChat: true)
        let cloudTerminal = CloudChatFocus.Shown(machine: "vm-1", key: "t", onCloud: true, isChat: false)
        let fronted = CloudChatFocus.Shown(machine: "mac", key: "m", fronts: ("vm-1", "chat-1"), onCloud: false, isChat: true)
        #expect(CloudChatFocus.resolve(byPerson: true, namesPlace: false, shown: localChat) == .asBefore)
        #expect(CloudChatFocus.resolve(byPerson: true, namesPlace: false, shown: cloudTerminal) == .asBefore)
        #expect(CloudChatFocus.resolve(byPerson: true, namesPlace: false, shown: nil) == .asBefore)
        #expect(CloudChatFocus.resolve(byPerson: false, namesPlace: false, shown: fronted) == .asBefore, "a script keeps its target")
        #expect(CloudChatFocus.resolve(byPerson: true, namesPlace: true, shown: fronted) == .asBefore, "an open that names its place keeps it")
    }

    /// A New Tab page from a Cloud chat: Terminal runs or types its one line there, a blank Browser opens the desktop;
    /// the page's own setup (keep), an address, an agent pick and several lines stay this Mac's.
    @Test func aNewTabPagesPicksFromACloudChat() {
        #expect(CloudChatFocus.pick(terminal: true, browser: false, text: " ls ", run: true, keep: false) == .terminal(typing: "ls\n"))
        #expect(CloudChatFocus.pick(terminal: true, browser: false, text: "", run: true, keep: false) == .terminal(typing: nil))
        #expect(CloudChatFocus.pick(terminal: true, browser: false, text: "git st", run: false, keep: false) == .terminal(typing: "git st"))
        #expect(CloudChatFocus.pick(terminal: true, browser: false, text: "a\nb", run: true, keep: false) == nil)
        #expect(CloudChatFocus.pick(terminal: true, browser: false, text: "claude /login", run: true, keep: true) == nil)
        #expect(CloudChatFocus.pick(terminal: false, browser: true, text: "  ", run: true, keep: false) == .browser)
        #expect(CloudChatFocus.pick(terminal: false, browser: true, text: "example.com", run: true, keep: false) == nil)
        #expect(CloudChatFocus.pick(terminal: false, browser: false, text: "hi", run: true, keep: false) == nil)
        #expect(CloudChatFocus.pick(terminal: true, browser: false, text: "npm i -g x", run: true, keep: false, picked: false) == nil,
                "the page's Install / Log In (not typed in its field) acts on this Mac's harness")
    }
}
