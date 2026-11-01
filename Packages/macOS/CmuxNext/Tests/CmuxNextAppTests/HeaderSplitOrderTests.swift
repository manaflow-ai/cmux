import CmuxNextActions
import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextDaemon
import Testing

/// The chat header's Terminal and Browser buttons (cx-00n1): they open on the chat's right by
/// RightColumnPlacement (``AgentChatTabActions/openTool``), never as a split right of the last one, and
/// each button still toggles its own tab. Runs the header's path against a store whose layout the
/// split actions and the right-column opens change as the daemon would.
@MainActor
struct HeaderSplitOrderTests {
    /// A workspace whose screen is one row of panes, left to right; each pane holds one tab.
    final class Row {
        let store = DaemonStore()
        let registry = ActionRegistry()
        private(set) var panes: [(pane: PaneID, surface: SurfaceID, kind: TabKind)] = [(1, 1, .other("agentChat"))]
        private var next: UInt64 = 2
        /// The page each page tab shows (the diff viewer's `diff`), by surface.
        private(set) var pages: [SurfaceID: String] = [:]
        /// The last invocation of each action the row handles.
        private(set) var invocations: [String: ActionInvocation] = [:]
        /// The chat's folder.
        let cwd = "/repo"
        /// Whether the app places the header's Terminal and Browser on the chat's right (openTool), at the
        /// right end of the row here; false: the chat is not shown, and the split actions run instead.
        var places = true
        /// The right-column opens the header asked for, in order.
        private(set) var tools: [(kind: RightColumnPlacement.Kind, cwd: String?)] = []

        static func id(_ surface: SurfaceID) -> String { "surface:\(surface.rawValue)" }
        var chat: String { Self.id(1) }
        /// The row's tab ids left to right.
        var tabs: [String] { panes.map { Self.id($0.surface) } }
        /// The row's tabs left to right, by kind.
        var order: [String] {
            panes.map {
                if pages[$0.surface] == "diff" { return "changes" }
                switch $0.kind { case .pty: return "terminal"; case .browser: return "browser"; default: return "chat" }
            }
        }

        init() {
            for (id, kind) in [("splitRight", TabKind.pty), ("splitDown", .pty), ("splitBrowserRight", .browser)] {
                registry.register(Action(id: ActionID(rawValue: id), title: id, invoke: { [unowned self] invocation in
                    invocations[id] = invocation
                    split(invocation.target?.id, kind: kind)
                }, handler: {}))
            }
            // The diff viewer's page tab, placed right of the tab it names (AgentBesidePlacement).
            registry.register(Action(id: "openDiffViewer", title: "openDiffViewer", invoke: { [unowned self] invocation in
                invocations["openDiffViewer"] = invocation
                if let surface = split(invocation.target?.id, kind: .conversation) { pages[surface] = "diff" }
                publish()
            }, handler: {}))
            // A preview's browser tab, placed right of the tab it names (AgentBesidePlacement).
            registry.register(Action(id: "openBrowser", title: "openBrowser", invoke: { [unowned self] invocation in
                invocations["openBrowser"] = invocation
                split(invocation.target?.id, kind: .browser)
            }, handler: {}))
            registry.register(Action(id: "closeTab", title: "closeTab", invoke: { [unowned self] invocation in
                panes.removeAll { Self.id($0.surface) == invocation.target?.id }
                publish()
            }, handler: {}))
            publish()
        }

        /// Split Right on the targeted tab's pane: the new pane lands just right of it.
        @discardableResult
        private func split(_ tab: String?, kind: TabKind) -> SurfaceID? {
            guard let index = panes.firstIndex(where: { Self.id($0.surface) == tab }) else { return nil }
            let surface = SurfaceID(rawValue: next)
            panes.insert((PaneID(rawValue: next), surface, kind), at: index + 1)
            next += 1
            publish()
            return surface
        }

        private func publish() {
            let layout = panes.dropFirst().reduce(LayoutNode.leaf(panes[0].pane)) { left, pane in
                .split(id: nil, resourceID: nil, direction: .right, ratio: 0.5, a: left, b: .leaf(pane.pane))
            }
            let snapshots = panes.map { pane in
                var tab = TabSnapshot(surface: pane.surface, kind: pane.kind, cwd: pane.surface == 1 ? cwd : nil)
                if let page = pages[pane.surface] { tab.conversation = ConversationTabRef(page: page) }
                return PaneSnapshot(id: pane.pane, tabs: [tab])
            }
            let screen = ScreenSnapshot(id: 1, layout: layout, panes: snapshots)
            store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w", screens: [screen])]))
        }

        func click(_ id: String, toggles: AgentChatSplitToggles, url: String? = nil) {
            var actions = AgentChatTabActions(tab: { [chat] in chat }, registry: { [registry] in registry })
            actions.openTool = { [unowned self] kind, cwd in
                guard places else { return false }
                tools.append((kind, cwd))
                userOpens(kind == .terminal ? .pty : .browser)
                return true
            }
            toggles.toggle(id, cwd: id == "splitRight" ? nil : cwd, url: url, chat: chat, store: store, actions: actions)
        }

        /// The user's own split (Cmd-D), at the right end of the row.
        func userOpens(_ kind: TabKind) {
            panes.append((PaneID(rawValue: next), SurfaceID(rawValue: next), kind))
            next += 1
            publish()
        }

        /// The user closes the tab at `index` (left to right) from the tab itself.
        func userCloses(_ index: Int) {
            panes.remove(at: index)
            publish()
        }

        /// The tab at `from` (left to right) dragged to `to`, as the user moves a pane.
        func move(_ from: Int, to: Int) {
            panes.insert(panes.remove(at: from), at: to)
            publish()
        }
    }

    /// Leo, 2026-10-31: "like having it go split instead of just adding a third colujmn",
    /// "just open it on the existing". Terminal then Browser both open on the chat's right (a tab in the
    /// pane holding that kind, else a split below it, RightColumnPlacement), never Split Right beside
    /// the terminal's pane.
    @Test func terminalThenBrowserOpenOnTheChatsRightNotAsAThirdColumn() {
        let row = Row(), toggles = AgentChatSplitToggles()
        row.click("splitRight", toggles: toggles)
        row.click("splitBrowserRight", toggles: toggles)
        #expect(row.tools.map(\.kind) == [.terminal, .browser])
        #expect(row.tools.map(\.cwd) == [nil, row.cwd])
        #expect(row.invocations["splitRight"] == nil && row.invocations["splitBrowserRight"] == nil)
        #expect(toggles.headerState(chat: row.chat, store: row.store).lit == ["splitBrowserRight", "splitRight"])
    }

    /// Terminal asks for a terminal: a person's Split Right from a chat opens the New Tab page
    /// (cx-jfo7), which the header's Terminal must not (cx-00n1). With the chat not shown (no
    /// right column to measure) the split actions run.
    @Test func terminalAsksForATerminal() {
        let row = Row(), toggles = AgentChatSplitToggles()
        row.places = false
        row.click("splitRight", toggles: toggles)
        #expect(row.invocations["splitRight"]?.opensTerminal == true)
        row.click("splitBrowserRight", toggles: toggles)
        #expect(row.invocations["splitBrowserRight"]?.opensTerminal == false)
    }

    /// Split Down (cx-kk7lm) asks for a terminal under the chat, even after Terminal opened one right
    /// of it, and its second click closes that terminal, not Terminal's.
    @Test func splitDownOpensATerminalUnderTheChatAndClosesIt() {
        let row = Row(), toggles = AgentChatSplitToggles()
        row.click("splitRight", toggles: toggles)
        let right = row.tabs[1]
        row.click("splitDown", toggles: toggles)
        #expect(row.invocations["splitDown"]?.target?.id == row.chat)
        #expect(row.invocations["splitDown"]?.opensTerminal == true)
        #expect(row.tabs.count == 3)
        #expect(toggles.headerState(chat: row.chat, store: row.store).lit.contains("splitDown"))
        row.click("splitDown", toggles: toggles)
        #expect(row.tabs == [row.chat, right])
    }

    /// A split the user closed is forgotten: the button never claims, and later closes, a terminal
    /// the user opened themselves.
    @Test func aButtonNeverClosesTheUsersOwnTerminal() {
        let row = Row(), toggles = AgentChatSplitToggles()
        row.click("splitRight", toggles: toggles)
        row.userCloses(1)
        row.click("splitRight", toggles: toggles)
        row.userOpens(.pty)
        let mine = row.tabs[2]
        row.click("splitRight", toggles: toggles)
        #expect(row.tabs == [row.chat, mine])
        #expect(toggles.headerState(chat: row.chat, store: row.store).lit == [])
    }

    @Test func eachButtonClosesItsOwnPaneAndReopensAtTheEnd() {
        let row = Row(), toggles = AgentChatSplitToggles()
        row.click("splitBrowserRight", toggles: toggles)
        row.click("splitRight", toggles: toggles)
        #expect(row.order == ["chat", "browser", "terminal"])
        row.click("splitBrowserRight", toggles: toggles)
        #expect(row.order == ["chat", "terminal"])
        row.click("splitBrowserRight", toggles: toggles)
        #expect(row.order == ["chat", "terminal", "browser"])
    }

    /// The header's Terminal opens in the chat's folder, the folder a split inherits; Ghostty's
    /// `split-inherit-working-directory = false` turns that off as for any split (cx-zld.1): the
    /// terminal names no folder, so the split starts in the home folder (NewTerminalStart).
    @Test func terminalInheritsTheChatsFolderOnlyWhenSplitsInherit() {
        let row = Row(), toggles = AgentChatSplitToggles()
        for inherits in [true, false] {
            var actions = AgentChatTabActions(tab: { [chat = row.chat] in chat }, registry: { [registry = row.registry] in registry })
            actions.splitInherits = { inherits }
            toggles.open("splitRight", cwd: row.cwd, chat: row.chat, store: row.store, actions: actions)
            #expect(row.invocations["splitRight"]?["cwd"]?.stringValue == (inherits ? row.cwd : nil), "inherits \(inherits)")
        }
        // A chat of another machine keeps its folder: the key is this Mac's (NewTerminalStart).
        var remote = AgentChatTabActions(tab: { [chat = row.chat] in chat }, registry: { [registry = row.registry] in registry })
        remote.splitInherits = { false }
        remote.local = { false }
        toggles.open("splitRight", cwd: row.cwd, chat: row.chat, store: row.store, actions: remote)
        #expect(row.invocations["splitRight"]?["cwd"]?.stringValue == row.cwd)
        // Browser names no folder either way.
        var actions = AgentChatTabActions(tab: { [chat = row.chat] in chat }, registry: { [registry = row.registry] in registry })
        actions.splitInherits = { false }
        toggles.open("splitBrowserRight", cwd: row.cwd, chat: row.chat, store: row.store, actions: actions)
        #expect(row.invocations["splitBrowserRight"]?["cwd"]?.stringValue == row.cwd)
    }
}
