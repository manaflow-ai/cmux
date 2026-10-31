import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextSidebar
import Testing
import CmuxNextLayout

/// What tabs are called outside their strip, and what errors say (op-next-theme toasts). A
/// sidebar row's tabs and the closed-tab toasts name a tab as its strip does
/// (`TabTitleResolver`): an agent chat by its chat, a page tab by its page, a New Tab page or a
/// blank browser tab "New Tab", never the `about:blank` address their records carry. No refusal
/// shows a raw object id.
@MainActor
struct ToastCopyTests {
    private static let host = "local"

    /// One pane: an agent chat, a diff page tab, a New Tab page and a blank browser tab. The
    /// first three are conversation tabs whose records are titled `about:blank`.
    private static func store() -> DaemonStore {
        let store = DaemonStore()
        var chat = TabSnapshot(surface: 1, kind: .conversation, title: "about:blank", url: "about:blank")
        chat.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: host, session: "s-chat", harness: "codex"))
        var diff = TabSnapshot(surface: 2, kind: .conversation, title: "about:blank", url: "about:blank")
        diff.conversation = ConversationTabRef(page: "diff")
        var newTab = TabSnapshot(surface: 3, kind: .conversation, title: "about:blank", url: "about:blank")
        newTab.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: host))
        let blank = TabSnapshot(surface: 4, kind: .browser, title: "", url: "about:blank")
        let pane = PaneSnapshot(id: 1, tabs: [chat, diff, newTab, blank])
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w", screens: [screen])]))
        return store
    }

    private final class DiffPage: InternalPageProvider {
        var page: InternalPageID { InternalPageID(rawValue: "diff") }
        var title: String { "Diff" }
        var symbol: String { "plusminus" }
        func makeView(for key: String, in window: WindowController?) -> NSView { NSView() }
        func title(for key: String) -> String { "cmux" }
    }

    @MainActor private struct Fixture {
        let store: DaemonStore
        let titles: TabTitleResolver
        let chat, diff, newTab, blank: TabModel
        var chatName: String { AgentChatTabTitle.untitled(chat.agentSession) }
    }

    private static func fixture() throws -> Fixture {
        let store = Self.store()
        let pages = InternalPageTabStore()
        pages.register(DiffPage())
        let newTab = try #require(store.tab(surface: 3))
        return Fixture(store: store, titles: TabTitleResolver(newTabPages: [newTab.id], pages: pages),
                       chat: try #require(store.tab(surface: 1)), diff: try #require(store.tab(surface: 2)),
                       newTab: newTab, blank: try #require(store.tab(surface: 4)))
    }

    /// Closing a tab group of one tab: its toast names the tab like its strip.
    @Test func theGroupCloseToastNamesEachTabLikeItsStrip() throws {
        let f = try Self.fixture()
        func toast(_ tab: TabModel) -> String { MiscHandlerStrings.tabClosed(CloseUndoToasts.title(of: tab, titles: f.titles)) }
        #expect(toast(f.chat) == MiscHandlerStrings.tabClosed(f.chatName))
        #expect(toast(f.diff) == MiscHandlerStrings.tabClosed("cmux"))
        #expect(toast(f.newTab) == MiscHandlerStrings.tabClosed(Strings.untitledBrowser))
        #expect(toast(f.blank) == MiscHandlerStrings.tabClosed(Strings.untitledBrowser))
        for tab in [f.chat, f.diff, f.newTab, f.blank] { #expect(!toast(tab).contains("about:blank")) }
        // A chat and a page are never "New Tab".
        #expect(f.chatName != Strings.untitledBrowser)
    }

    /// A sidebar row's tabs carry the strip's names too.
    @Test func aSidebarRowNamesEachTabLikeItsStrip() throws {
        let f = try Self.fixture()
        let pane = try #require(f.store.pane(containing: 1))
        let workspace = try #require(f.store.workspace(containing: pane.handle))
        let row = SidebarMapping.shared.row(workspace, machine: .local, newTabPages: [f.newTab.id],
                                            newTabTitle: Strings.untitledBrowser, tabTitle: { f.titles.title($0) })
        #expect(row.tabs.map(\.title) == [f.chatName, "cmux", Strings.untitledBrowser, Strings.untitledBrowser])
    }

    /// Refusals about a missing object (the toast, the socket's `not_found`) are sentences, never
    /// the object's raw id.
    @Test func noRefusalShowsARawID() {
        let id = "obj_01JABCDEF0123456789"
        let reasons: [(String, String)] = [
            ("noWorkspace", RefusalStrings.noWorkspace(id)),
            ("noWorkspaceGroup", RefusalStrings.noWorkspaceGroup(id)),
            ("noTab", RefusalStrings.noTab(id)),
            ("noPaneID", RefusalStrings.noPaneID(id)),
            ("paneHasNoWorkspaceView", RefusalStrings.paneHasNoWorkspaceView(id)),
            ("tabHasNoLiveContent", RefusalStrings.tabHasNoLiveContent(id)),
            ("noScreen", RefusalStrings.noScreen(id)),
            ("noClosedItem", RefusalStrings.noClosedItem(id)),
            ("noColumnShown", RefusalStrings.noColumnShown(id)),
            ("paneHasNoDaemonHandle", RefusalStrings.paneHasNoDaemonHandle(id)),
            ("noOpenTabGroup", RefusalStrings.noOpenTabGroup(id)),
            ("noSavedTabGroup", RefusalStrings.noSavedTabGroup(id)),
            ("workspaceHasNoPane", RefusalStrings.workspaceHasNoPane(id)),
            ("noWindow", RefusalStrings.noWindow(id)),
            ("noScreenGroup", ScreenStrings.noScreenGroup(id)),
        ]
        for (name, message) in reasons {
            #expect(!message.contains(id), "\(name): \(message)")
            #expect(!message.isEmpty, "\(name)")
        }
    }

    /// The names a deep link's ignored parameters are shown under come from whatever wrote the
    /// link -- another app, a page, an agent's message -- so the toast shows them the way the web
    /// page does (schemas/deeplinks/agent-link.json `ignoredOrder`): inside the charset a parameter
    /// name may have, and at most eight. A crafted link cannot put its own sentence, a URL or a
    /// writing-direction mark into cmux's own chrome.
    @Test func anIgnoredParameterNameCannotCarryTextIntoTheToast() throws {
        let crafted = "Your session expired, sign in again at https://cmux.example\u{202E} "
        let message = try #require(RefusalStrings.linkParametersIgnored([crafted, "ok_name", "\u{2713}"]))
        #expect(!message.contains("sign in again"), "\(message)")
        #expect(!message.contains("https://"), "\(message)")
        #expect(!message.contains("\u{202E}"), "\(message)")
        // A name the charset leaves nothing of is still counted, as the page counts it.
        #expect(message.contains("ok_name, ?"), "\(message)")

        let shown = try #require(RefusalStrings.linkParametersIgnored((1...12).map { "p\($0)" }))
        #expect(shown.contains("p8"), "\(shown)")
        #expect(!shown.contains("p9"), "\(shown)")
    }

    /// Cutting a name to the charset can leave the name of a parameter the link did use
    /// (`?host%20=x` beside `?host=big-red`): saying cmux ignored `host` over the chat that
    /// link's host opened would contradict the link, so that name is dropped unsaid, as the page
    /// drops it (schemas/deeplinks/agent-link.json `ignoredOrder`). With nothing else to name,
    /// there is no toast at all.
    @Test func aStrayNameNeverDeniesAParameterTheLinkUsed() throws {
        let message = try #require(RefusalStrings.linkParametersIgnored(["host ", "cwd"], used: ["host"]))
        #expect(!message.contains("host"), "\(message)")
        #expect(message.contains("cwd"), "\(message)")
        #expect(RefusalStrings.linkParametersIgnored(["host ", "(host)"], used: ["host"]) == nil)
        // A name the link does not carry a value for is still named: `?host=` names no machine.
        let named = try #require(RefusalStrings.linkParametersIgnored(["host"], used: ["message"]))
        #expect(named.contains("host"), "\(named)")
    }

    /// Two stray names the charset leaves the same of are one name, as the page counts what it
    /// shows rather than what the link wrote: `?cwd%20=x&cwd%09=y` says `cwd` once, and two names
    /// with nothing printable left say `?` once.
    @Test func twoStrayNamesShownTheSameAreSaidOnce() throws {
        let message = try #require(RefusalStrings.linkParametersIgnored(["cwd ", "cwd\t", "\u{2713}", "\u{202E}"]))
        #expect(message.contains("cwd, ?"), "\(message)")
        #expect(!message.contains("cwd, cwd"), "\(message)")
        #expect(!message.contains("?, ?"), "\(message)")
    }
}
