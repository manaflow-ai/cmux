import AppKit
import CmuxNextActions
import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextTestSupport
import Foundation
import Testing

/// Lawrence 2026-11-15: "i cmd click on …/grok-bot-parity/PRODUCT.md. and it opened in bottom right. i
/// expected it to just open in the right side tho". A terminal on the left and one browser pane on the
/// right: the Cmd-clicked Markdown file made a split below the browser pane instead of a tab in it. A
/// link or file the person opens goes into the pane already on the right as a new tab, whatever that
/// pane holds; only with no pane on the right does it split right, and never into the source's own pane.
/// Runs ``LinkOpener`` (every terminal, chat, page and browser Cmd-click's path) against a same-tree daemon.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"), .closesItsWindows)
struct CmdClickOpensInRightPaneTests {
    enum Opened: String, CaseIterable, Sendable {
        case markdown, html, webLink
    }

    /// The user's layout: terminal left, one browser pane right. A file or link is a tab in that pane, no new split.
    @Test(arguments: Opened.allCases)
    func aCmdClickBesideABrowserPaneOpensATabThere(_ opened: Opened) async throws {
        try await Self.withLayout(right: .browser) { services, content, source, right, _ in
            let panes = Set(content.panes.keys)
            let tab = try await Self.open(opened, services, from: source)
            try await PinnedPageTests.until({ right.pane.tabs.contains { $0.id == tab } },
                                            report: { "the \(opened) open is not a tab in the pane on the right: " + Self.describe(content) })
            #expect(Set(content.panes.keys) == panes, "the \(opened) open made a new split: \(Self.describe(content))")
            #expect(!source.pane.tabs.contains { $0.id == tab }, "the \(opened) open stayed in the source pane: \(Self.describe(content))")
        }
    }

    /// A terminal on the right (a plain Split Right): a file or link is a tab there too, never a split below it.
    @Test(arguments: Opened.allCases)
    func aCmdClickBesideATerminalPaneOpensATabThere(_ opened: Opened) async throws {
        try await Self.withLayout(right: .terminal) { services, content, source, right, _ in
            let panes = Set(content.panes.keys)
            let tab = try await Self.open(opened, services, from: source)
            try await PinnedPageTests.until({ right.pane.tabs.contains { $0.id == tab } },
                                            report: { "the \(opened) open is not a tab in the pane on the right: " + Self.describe(content) })
            #expect(Set(content.panes.keys) == panes, "the \(opened) open made a new split: \(Self.describe(content))")
        }
    }

    /// Nothing on the right of a pane under twice the chat floor: the open still splits right, never a tab in the source.
    @Test(arguments: Opened.allCases)
    func aNarrowSourceWithNothingOnItsRightStillSplitsRight(_ opened: Opened) async throws {
        try await PinnedPageTests.withApp { services, _ in
            let content = try #require(services.windows.active?.workspaceContent)
            let model = try #require(services.daemon.store.workspaces.first?.screens.first?.panes.first)
            let source = try #require(services.paneController(for: model))
            services.windows.active?.window?.setFrame(NSRect(x: 0, y: 0, width: 800, height: 700), display: true)
            try await PinnedPageTests.until({ (LinkOpener.width(of: source) ?? .infinity) < 2 * RightColumnPlacement.minimumChatWidth },
                                            report: { "the source pane did not narrow: \(LinkOpener.width(of: source) ?? -1)" })
            PaneHandlers.focus(source.layoutPaneID, in: content)
            services.linkOpener.placement = { .splitRight }
            let panes = Set(content.panes.keys)
            let tab = try await Self.open(opened, services, from: source)
            @MainActor func shown() -> PaneController? {
                content.panes.first { !panes.contains($0.key) && $0.value.pane.tabs.contains { $0.id == tab } }?.value
            }
            try await PinnedPageTests.until({ shown() != nil },
                                            report: { "the \(opened) open is not in a new split on the right: " + Self.describe(content) })
            #expect(!source.pane.tabs.contains { $0.id == tab }, "the \(opened) open stayed in the source pane: \(Self.describe(content))")
        }
    }

    /// The second report (CleanShot 4.58.16 PM): `cmux browser open` run in a terminal with a pane on its right
    /// put the page in the terminal's own pane. The CLI aims `openBrowser` at its caller's terminal tab; the
    /// page goes into the pane on the right as a Cmd-click's does. A plain split is one column to `identify`,
    /// so the CLI cannot place it itself.
    @Test(arguments: [Right.browser, .terminal])
    func aCLIBrowserFromATerminalOpensInThePaneOnItsRight(_ kind: Right) async throws {
        try await Self.withLayout(right: kind) { services, content, source, right, connection in
            let panes = Set(content.panes.keys)
            // The harness's first pane holds an agent chat: give it the terminal the person types `cmux browser open` in.
            let shell = try await connection.newTab(in: source.pane.handle).surface
            try await PinnedPageTests.until({ source.pane.tabs.contains { $0.surface == shell && $0.terminalID != nil } },
                                            report: { "the source's new terminal has no id: \(source.pane.tabs.map { "\($0.id) \($0.kind)" })" })
            let terminal = try #require(source.pane.tabs.first { $0.surface == shell })
            let before = Set(services.daemon.store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).map(\.id))
            var invocation = ActionInvocation(target: ActionTargetRef(kind: .tab, id: terminal.id),
                                              arguments: ["url": .string("http://127.0.0.1:9/from-the-cli")], origin: .cli)
            invocation.callerTerminal = terminal.terminalResourceID?.rawValue ?? terminal.terminalID?.rawValue
            #expect(services.registry.perform("openBrowser", invocation: invocation))
            @MainActor func made() -> String? {
                services.daemon.store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs)
                    .first { !before.contains($0.id) && !ProvisionalTab.isProvisional($0.id) }?.id
            }
            try await PinnedPageTests.until({ made() != nil }, report: { "the CLI's browser made no tab" })
            let tab = try #require(made())
            try await PinnedPageTests.until({ right.pane.tabs.contains { $0.id == tab } },
                                            report: { "the CLI's browser is not a tab in the pane on the right: " + Self.describe(content) })
            #expect(Set(content.panes.keys) == panes, "the CLI's browser made a new split: \(Self.describe(content))")
            #expect(!source.pane.tabs.contains { $0.id == tab }, "the CLI's browser stayed in the terminal's pane: \(Self.describe(content))")
        }
    }

    enum Right: Sendable { case browser, terminal }

    /// A wide window, the first pane (a terminal) split right; the right pane holds one browser tab or its terminal.
    private static func withLayout(right kind: Right,
                                   _ body: (AppServices, WorkspaceContentController, PaneController, PaneController, DaemonConnection) async throws -> Void) async throws {
        try await PinnedPageTests.withApp { services, connection in
            let content = try #require(services.windows.active?.workspaceContent)
            let model = try #require(services.daemon.store.workspaces.first?.screens.first?.panes.first)
            let source = try #require(services.paneController(for: model))
            // Wide enough that the old rule's split below the right pane passes its width floors.
            services.windows.active?.window?.setFrame(NSRect(x: 0, y: 0, width: 2000, height: 1000), display: true)
            try await PinnedPageTests.until({ (LinkOpener.width(of: source) ?? 0) >= 2 * RightColumnPlacement.minimumChatWidth },
                                            report: { "the terminal's pane did not widen: \(LinkOpener.width(of: source) ?? -1)" })
            let panes = Set(content.panes.keys)
            #expect(services.registry.perform("splitRight", invocation: ActionInvocation(origin: .user)))
            @MainActor func confirmed() -> PaneController? {
                content.panes.first { !panes.contains($0.key) && $0.value.pane.tabs.contains { !ProvisionalTab.isProvisional(surface: $0.surface) } }?.value
            }
            try await PinnedPageTests.until({ confirmed() != nil }, report: { "the split did not confirm" })
            let right = try #require(confirmed())
            if kind == .browser {
                let terminals = right.pane.tabs.map(\.surface).filter { !ProvisionalTab.isProvisional(surface: $0) }
                // A closed loopback port: the page never loads, and nothing leaves the machine.
                let browser = try await connection.newFrontendBrowserTab(url: "http://127.0.0.1:9/right", engine: .webkit, in: right.pane.handle, activate: true)
                try await PinnedPageTests.until({ right.pane.tabs.contains { $0.surface == browser.surface } },
                                                report: { "the pane on the right did not list its browser tab" })
                for terminal in terminals { try await connection.closeTab(terminal) }
                try await PinnedPageTests.until({ right.pane.tabs.map(\.surface) == [browser.surface] && content.panes[right.layoutPaneID] === right },
                                                report: { "the pane on the right does not hold its browser tab alone: " + describe(content) })
            }
            try await PinnedPageTests.until({ !RightColumnPlacement.column(beside: source.layoutPaneID,
                                                                           frames: content.layoutView.navigationFrames(ofScreenContaining: source.layoutPaneID)).isEmpty },
                                            report: { "the right column was not laid out: " + describe(content) })
            PaneHandlers.focus(source.layoutPaneID, in: content)
            try await PinnedPageTests.until({ content.focusedPane === source })
            services.linkOpener.placement = { .splitRight }
            try await body(services, content, source, right, connection)
        }
    }

    /// Opens `opened` from `source` as the terminal's Cmd-click does (``LinkOpener/openFile`` for a path,
    /// ``LinkOpener/openWeb`` for a URL) and returns the new tab once the daemon lists it.
    private static func open(_ opened: Opened, _ services: AppServices, from source: PaneController) async throws -> String {
        let store = services.daemon.store
        let before = Set(store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).map(\.id))
        switch opened {
        case .markdown, .html:
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cn-cmdclick-\(UUID().uuidString.prefix(8))")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent(opened == .markdown ? "PRODUCT.md" : "PRODUCT.html")
            try (opened == .markdown ? "# Product\n" : "<!doctype html><title>Combined product</title>").write(to: file, atomically: true, encoding: .utf8)
            #expect(services.linkOpener.openFile(file, from: source))
        case .webLink:
            #expect(services.linkOpener.openWeb(URL(string: "http://127.0.0.1:9/clicked")!, from: source, background: false))
        }
        @MainActor func made() -> String? {
            store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).first { !before.contains($0.id) && !ProvisionalTab.isProvisional($0.id) }?.id
        }
        try await PinnedPageTests.until({ made() != nil }, report: { "the \(opened) open made no tab" })
        return try #require(made())
    }

    /// Each pane: focused or not, its selected tab and its tabs.
    private static func describe(_ content: WorkspaceContentController) -> String {
        let focused = content.focusedPane
        return content.panes.values.map { pane in
            "\(pane.layoutPaneID)\(pane === focused ? " (focused)" : ""): \(pane.stripModel.selectedID?.rawValue ?? "none") of \(pane.pane.tabs.map(\.id))"
        }.sorted().joined(separator: "; ")
    }
}
