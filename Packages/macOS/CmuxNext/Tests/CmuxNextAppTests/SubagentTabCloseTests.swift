import AppKit
import CmuxNextActions
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextLayout
@testable import CmuxNextTabs
import Foundation
import Testing

/// Lawrence 2026-10-22: "can't 'x' out of subagent tab". A click on a subagent in a chat opens the
/// subagent's pane (`chat.subagentPane`, AgentSubagentPanes): a second tab on the chat's own acpmux
/// session, beside the chat. Its x must close it, as any tab's does. Runs the app's open path
/// (`AgentTabStore.openBeside`, as `openSubagent` places it) against a same-tree cmux-tui daemon,
/// then presses the x with the mouse.
@MainActor @Suite(.serialized, .timeLimit(.minutes(4)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct SubagentTabCloseTests {
    static let session = "chat-subagent-tab-close"

    /// Where the chat is when its subagent's pane opens.
    enum Layout: String, CaseIterable, CustomTestStringConvertible {
        /// Main pane layout on, the chat alone: it docks left and the pane opens on its right.
        case loneChat
        /// Main pane layout off: the pane is a new split right of the chat.
        case split
        /// Main pane layout on, the chat already in its dock with a column beside it: the pane is a tab there.
        case docked
        var testDescription: String { rawValue }
    }

    @Test(arguments: Layout.allCases)
    func aSubagentTabClosesWithItsX(_ layout: Layout) async throws {
        // The Debug override applies only once the store is on and knows the key (a fresh suite
        // process has neither); the set is required, so a refused one fails here, not silently.
        let tunables = TunableStore.shared, overrideKey = MainPaneLayout.debugOverride.key
        tunables.activate(file: nil)
        tunables.register([MainPaneLayout.debugOverride.descriptor])
        let prior = tunables.override(overrideKey)
        defer { tunables.set(overrideKey, prior) }
        try #require(tunables.set(overrideKey, (layout == .split ? MainPaneOverride.off : .on).tunableValue) != nil, "the main pane override was refused")
        try await PinnedPageTests.withApp { services, connection in
            #expect(MainPaneLayout.isOn(services: services) == (layout != .split), "main pane layout is not as the case needs")
            let store = services.daemon.store
            let tabs = services.agentTabs
            tabs.localHost = AgentSessionRef.host(installID: "cn-subagent-tab-close")
            let model = try #require(store.workspaces.first?.screens.first?.panes.first)
            let first = try #require(model.tabs.first?.surface)

            // The chat: alone in its pane, or in the chat dock with the shell's column on its right.
            let record = AgentSessionRef(host: try #require(tabs.localHost), hostName: "This Mac", session: Self.session, harness: "claude")
            let chat = try await connection.request(NewConversationTabRequest(agentSession: record, pane: model.handle))
            if layout == .docked {
                try await PinnedPageTests.until({ store.tab(surface: chat.surface) != nil })
                let tab = try #require(store.tab(surface: chat.surface))
                var docked: Bool?
                TabMoves.toNewDockColumn(tab, anchor: model, edge: .left, role: .agentChat, services: services) { docked = $0 }
                try await PinnedPageTests.until({ docked != nil && services.locateTab(tab.id).map { $0.1 !== model } == true },
                                                report: { Self.describe(services) })
                try #require(docked == true, "the chat did not dock: \(Self.describe(services))")
            } else {
                try await connection.closeTab(first)
                try await PinnedPageTests.until({ store.tab(surface: chat.surface) != nil && store.tab(surface: first) == nil })
            }
            let chatID = try #require(store.tab(surface: chat.surface)).id

            // The subagent's pane, opened as a click on its row opens it.
            var created: String?
            var moved: Bool?
            let opened = tabs.openBeside(chatID, direction: "right", origin: .user, main: chatID, open: { pane, daemon in
                try tabs.open(in: pane, of: daemon, session: Self.session)
            }, created: { created = $0 }, finished: { moved = $0 })
            try #require(opened, "the subagent pane did not open")
            try await PinnedPageTests.until({ moved != nil }, within: .seconds(30), report: { Self.describe(services) })
            let key = try #require(created.map(tabs.resolve))
            // The case ran its own placement: the chat docked left, or (main pane layout off) a plain split.
            let docks = services.windows.active?.workspaceContent?.workspace.screens.contains { $0.columns.contains { $0.dock != nil } }
            #expect(docks == (layout != .split), "the subagent pane opened in the wrong layout: \(Self.describe(services))")
            let (_, pane) = try #require(services.locateTab(key), "the subagent tab is gone: \(Self.describe(services))")
            let controller = try #require(services.paneController(for: pane), "no pane shows the subagent tab: \(Self.describe(services))")
            let id = StripTabID(key)
            try await PinnedPageTests.until({ controller.stripModel.tab(id) != nil && controller.view.stripView.cells[id] != nil },
                                            report: { Self.describe(services) })
            #expect(controller.stripModel.tab(id)?.isClosable == true, "the subagent tab has no x: \(Self.describe(services))")

            // Its x, pressed with the mouse in the window: the press lands on the strip, and the tab
            // goes and stays gone.
            let window = try #require(controller.view.window, "the subagent's pane is in no window")
            window.orderFrontRegardless()
            defer { window.orderOut(nil) }
            // A fixed size, whatever the host's screen: panes wide enough for a chat's tools to share
            // their tab row (in a narrow one the chat sits under its tabs and covers no x).
            window.setFrame(NSRect(x: 0, y: 0, width: 1600, height: 1000), display: false)
            window.contentView?.layoutSubtreeIfNeeded()
            // The chats' tools share their panes' tab rows, as a loaded chat page's do.
            for view in [tabs.existingView(chatID), tabs.existingView(key)].compactMap({ $0 }) { view.model.tabRow.report(width: 120) }
            let strip = controller.view.stripView
            // The subagent's chat shows in that pane and takes the tab row once the pane lays out again.
            @MainActor func sharesRow() -> Bool {
                window.contentView?.layoutSubtreeIfNeeded()
                guard let view = tabs.existingView(key), let page = view.page, view.window === window, !view.isHiddenOrHasHiddenAncestor else { return false }
                return page.convert(page.bounds, to: nil).intersects(strip.convert(strip.bounds, to: nil))
            }
            try await PinnedPageTests.until(sharesRow, report: {
                let view = tabs.existingView(key)
                return "the subagent's chat never shares its tab row: view \(view.map { "in window \($0.window === window), hidden \($0.isHiddenOrHasHiddenAncestor), frame \($0.convert($0.bounds, to: nil))" } ?? "none"), "
                    + "tools \(view?.model.tabRow.toolsWidth ?? -1), strip \(strip.convert(strip.bounds, to: nil)), \(Self.describe(services))"
            })
            let point = try Self.closeButton(id, in: strip)
            // A Chromium chat page is a window above the whole window: one over the x leaves a hole there.
            // The subagent's chat shows in that pane and shares its tab row, so its page is over the x.
            var covering: [String] = []
            for (name, view) in [("chat", tabs.existingView(chatID)), ("subagent", tabs.existingView(key))] {
                guard let view, let page = view.page, view.window === window, !view.isHiddenOrHasHiddenAncestor,
                      page.convert(page.bounds, to: nil).contains(point) else { continue }
                covering.append(name)
                #expect(page.nativeRects.contains { page.convert($0, to: nil).contains(point) },
                        "the \(name)'s page covers the x with no hole: holes \(page.nativeRects.map { page.convert($0, to: nil) }), x at \(point)")
            }
            let shares = "window \(window.frame), pane \(controller.view.frame.size), x at \(point), \(Self.describe(services))"
            #expect(covering.contains("subagent"), "the subagent's chat does not share its tab row, so nothing checks its hole: \(shares)")
            let hit = window.contentView?.hitTest(window.contentView?.superview?.convert(point, from: nil) ?? point)
            #expect(hit.map { $0 === strip || $0.isDescendant(of: strip) } == true,
                    "the x is under \(hit.map { String(describing: type(of: $0)) } ?? "nothing"), not the strip: \(Self.describe(services))")
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                                            pressure: type == .leftMouseUp ? 0 : 1))
                window.sendEvent(event)
            }
            try await PinnedPageTests.until({ services.locateTab(key) == nil }, within: .seconds(10),
                                            report: { "the x left the subagent tab open: " + Self.describe(services) })
            try await Task.sleep(for: .seconds(2))
            #expect(services.locateTab(key) == nil, "the subagent tab came back: \(Self.describe(services))")
            #expect(store.tab(id: chatID) != nil, "the x closed the chat")
        }
    }

    /// The center of tab `id`'s close button in window coordinates, with the pointer over the tab.
    private static func closeButton(_ id: StripTabID, in strip: TabStripView) throws -> CGPoint {
        let cell = try #require(strip.cells[id])
        TabStripDebug.pointerMoved(in: strip, to: strip.convert(CGPoint(x: cell.frame.midX, y: cell.frame.midY), from: strip.tabsClip))
        let rect = try #require(cell.closeButtonRect, "the subagent tab shows no x under the pointer")
        let point = CGPoint(x: cell.frame.minX + rect.midX, y: cell.frame.minY + rect.midY)
        return strip.convert(strip.convert(point, from: strip.tabsClip), to: nil)
    }

    private static func describe(_ services: AppServices) -> String {
        guard let content = services.windows.active?.workspaceContent else { return "no workspace" }
        let screens = content.workspace.screens.map { screen in
            let columns = screen.columns.map { "\($0.layout.paneIDs.map(\.rawValue))\($0.dock.map { " dock(\($0.edge),pinned:\($0.isPinned))" } ?? "")" }
            let panes = screen.panes.map { pane in
                let strip = services.paneController(for: pane).map { " strip \($0.stripModel.orderedTabs.map { "\($0.id.rawValue)\($0.isClosable ? "" : "(no x)")" })" } ?? " (no controller)"
                return "pane \(pane.handle.rawValue): \(pane.tabs.map { "\($0.id)\($0.agentSession == nil ? "" : "[chat]")" })\(strip)"
            }
            return "columns \(columns); " + panes.joined(separator: "; ")
        }
        return screens.joined(separator: " | ")
    }
}
