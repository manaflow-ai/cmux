#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import CmuxNextActions
import CmuxNextBrowser
import CmuxNextDaemon
import CmuxNextSettings

private typealias JSON = CmuxNextSettings.JSONValue

/// `debug.new_tab {action: "bench_create", command}` (DEBUG builds): the instant-create budget of
/// Cmd-N, Cmd-T, Ctrl-` (New Terminal Tab), Cmd-D and Cmd-Shift-D, each driven through the real
/// key path (`debug.key`).
///
/// Per run it reports, in ms after the key:
/// - `key_ms`: the key's synchronous main-thread time (handler included);
/// - `visible_ms`: the first display frame at which the result shows (Cmd-N: the window shows
///   another workspace; Cmd-T, Ctrl-`: the focused pane shows another tab; Cmd-D / Cmd-Shift-D: the
///   window's focused pane is a new pane);
/// - `confirmed_ms`: the first frame at which the daemon's object replaced the provisional one
///   (no `pending_tab_` id, no provisional pane handle), or null within 5 s;
/// - `frames_to_visible`: display frames from the key to `visible_ms` (1 = the next frame);
/// - `spans`: the main-thread spans and marks `BenchSpans` recorded (handler stages, daemon reply).
///
/// `new_browser` (PL-cef-tab, `scripts/cmux-next/cef-tab-bench.py`) is Cmd-Shift-L, or with `run` an action id,
/// that action run as a person's (with `url`: a link opened in a new tab; `openBrowser.webkit`):
/// visible once the pane shows the new tab selected (its themed pane; `chrome_ms`: its browser view in it); `page_ms` the
/// first frame after its page painted (first contentful paint, or its load ended); the spans
/// include Chromium's main-thread steps (`CEFBenchMarks`: `cef.create_window`, `cef.tab_add`, ...).
/// `link_right` opens `url` (default example.com) from the focused pane as a link opened to the right (split right):
/// visible once the window shows another pane, `page_ms` once that pane's page painted (quick arm: ``openLinkRight(_:_:_:)``). `dock_respawn` docks the focused pane's lone tab into a new left
/// dock and leaves a fresh terminal (a lone chat's new tab, ``ChatColumnPlacement``): visible once the window shows another pane.
@MainActor
enum DebugInstantCreateBench {
    private static let frames = BenchFrames()

    enum Command: String, CaseIterable {
        case newWorkspace = "new_workspace", newTab = "new_tab", newTerminal = "new_terminal", splitRight = "split_right", splitDown = "split_down", newBrowser = "new_browser", linkRight = "link_right", splitBrowser = "split_browser", dockRespawn = "dock_respawn"

        var key: (String, [String]) {
            switch self {
            case .newWorkspace: ("n", ["command"])
            case .newTab: ("t", ["command"])
            case .newTerminal: ("`", ["control"])
            case .splitRight: ("d", ["command"])
            case .splitDown: ("d", ["command", "shift"])
            case .newBrowser, .linkRight, .splitBrowser, .dockRespawn: ("l", ["command", "shift"])
            }
        }
    }

    static func run(_ params: [String: CmuxNextSettings.JSONValue], _ controller: WindowController, _ services: AppServices) async -> CmuxNextSettings.JSONValue {
        guard let command = params["command"]?.stringValue.flatMap(Command.init(rawValue:)) else {
            return .object(["error": .string("command: one of \(Command.allCases.map(\.rawValue).joined(separator: ", "))")])
        }
        if params["untimed"]?.boolValue == true, command == .linkRight { return openLinkRight(params, controller, services) } // replies at once
        let before = Probe(controller)
        let shownBrowsers = Probe.browserTabs(controller) // a page painted before the press is never the new one
        let pageQuery = params["from_pane"] != nil ? params["url"]?.stringValue.flatMap(URL.init(string:))?.query : nil // its own page only
        let (key, modifiers) = command.key
        frames.start()
        BenchSpans.begin()
        services.cache.cef.benchMarks.arm { name, milliseconds in BenchSpans.mark(name, milliseconds: milliseconds) }
        defer { services.cache.cef.benchMarks.arm(nil) }
        let start = ContinuousClock.now
        if command == .linkRight {
            openLinkRight(params, controller, services)
        } else if command == .dockRespawn, let pane = controller.content?.focusedPane, let tab = pane.pane.tabs.first {
            TabMoves.toNewDockColumn(tab, anchor: pane.pane, edge: .left, role: .agentChat, respawn: .terminal(SpawnOptions()), services: services)
        } else if let action = params["run"]?.stringValue ?? (command == .splitBrowser ? "splitBrowserRight" : nil) {
            let arguments = params["url"]?.stringValue.map { ["url": ActionValue.string($0)] } ?? [:]
            _ = services.registry.perform(ActionID(rawValue: action), invocation: ActionInvocation(arguments: arguments))
        } else { _ = DebugKey.send(["key": .string(key), "modifiers": .array(modifiers.map(JSON.string)), "window": .string(controller.state.id)], services: services) }
        let keyMilliseconds = BenchSpans.ms(.now - start)
        let visible = await frames.settled(until: { before.changed(command, Probe(controller)) }, start: start, window: 0, deadline: 5_000)
        let chrome = visible == nil || command != .newBrowser ? nil : await frames.settled(until: { Probe(controller).browser != nil }, start: start, window: 0, deadline: 5_000)
        // A link or browser opened to the right: its new pane's page (any shown pane of the window), first paint or load end.
        let opensRight = command == .linkRight || command == .splitBrowser
        let page = visible == nil || (command != .newBrowser && !opensRight) ? nil
            : await frames.settled(until: { opensRight ? Probe.anyPagePainted(controller, services, besides: shownBrowsers, query: pageQuery) : Probe(controller).pagePainted(services) },
                                   start: start, window: 0, deadline: 5_000)
        let confirmed = visible == nil ? nil
            : await frames.settled(until: { Probe(controller).confirmed(command) }, start: start, window: 0, deadline: 5_000)
        let spans = BenchSpans.end()
        let stats = frames.stop()
        var refresh = 1_000.0 / 60
        if case .object(let fields) = stats, let value = fields["refresh_ms"]?.doubleValue, value > 0 { refresh = value }
        return .object([
            "command": .string(command.rawValue),
            "key_ms": .number(keyMilliseconds),
            "visible_ms": visible.map { .number($0) } ?? .null,
            "confirmed_ms": confirmed.map { .number($0) } ?? .null,
            "page_ms": page.map { .number($0) } ?? .null, "chrome_ms": chrome.map { .number($0) } ?? .null,
            "engine": .string(Probe(controller).browser.map { $0.tab.engineKind == .cef ? "cef" : "webkit" } ?? "none"),
            "spare_window": .string(services.cache.cef.spareWindowState),
            "frames_to_visible": visible.map { .number(($0 / refresh).rounded(.up)) } ?? .null,
            "main_thread_spans_ms": .number(spans.reduce(0) { $0 + $1.milliseconds }),
            "spans": .array(spans.map { .object(["name": .string($0.name), "at": .number($0.start), "ms": .number($0.milliseconds)]) }),
            "frames": stats,
        ])
    }

    /// `url` opened to the right (split right) from the focused pane, or the pane `from_pane` names: the quick arm's untimed press (`untimed`, the reply at once with its `source_pane`, so the spare window is taken) moved the focus to that link's browser pane, where a link is a tab, no pane to time.
    @discardableResult private static func openLinkRight(_ params: [String: CmuxNextSettings.JSONValue], _ controller: WindowController, _ services: AppServices) -> CmuxNextSettings.JSONValue {
        let named = params["from_pane"]?.stringValue.flatMap(UInt64.init).flatMap { handle in controller.content?.panes.values.first { $0.pane.handle.rawValue == handle } }
        guard let source = named ?? controller.content?.focusedPane, let url = URL(string: params["url"]?.stringValue ?? "https://example.com/") else { return .null }
        let placement = services.linkOpener.placement
        services.linkOpener.placement = { .splitRight }
        services.linkOpener.openWeb(url, from: source, background: false)
        services.linkOpener.placement = placement
        return .object(["command": .string(Command.linkRight.rawValue), "untimed": .bool(true), "source_pane": .string(String(source.pane.handle.rawValue))])
    }

    /// What the window shows, read each frame.
    private struct Probe {
        var workspace: String?
        var pane: ObjectIdentifier?
        var paneHandle: UInt64?
        var paneCount: Int
        var tab: String?
        /// The focused pane's browser, when its view is in the pane and the tab is selected in the strip.
        var browser: BrowserEntry?
        var selected: String? // the focused pane's selected tab in its strip

        init(_ controller: WindowController) {
            let content = controller.content
            workspace = content?.workspace.id
            let focused = content?.focusedPane
            pane = focused.map(ObjectIdentifier.init)
            paneHandle = focused?.pane.handle.rawValue
            paneCount = content?.panes.count ?? 0
            tab = focused?.currentTabKey
            selected = focused?.stripModel.selectedID?.rawValue
            if let focused, focused.view.hostsContent, focused.stripModel.selectedID?.rawValue == tab,
               case .browser(let entry) = focused.currentContent { browser = entry }
        }

        /// The browser tabs the window's panes show.
        static func browserTabs(_ controller: WindowController) -> Set<String> {
            Set(controller.content?.panes.values.compactMap { pane in
                if case .browser(let entry) = pane.currentContent { entry.tab.id.rawValue } else { nil }
            } ?? [])
        }

        /// Whether a pane of the window shows a browser, other than `besides` (with `query`: at that query), whose page painted (``pagePainted(_:)``).
        static func anyPagePainted(_ controller: WindowController, _ services: AppServices, besides: Set<String>, query: String? = nil) -> Bool {
            controller.content?.panes.values.contains { pane in
                guard pane.view.hostsContent, case .browser(let entry) = pane.currentContent,
                      !besides.contains(entry.tab.id.rawValue) else { return false }
                if let query, entry.tab.state.url?.query != query { return false }
                if case .finished = entry.tab.state.phase { return true }
                return services.cache.cef.benchMarks.firstPaints[entry.tab.id.rawValue] != nil
            } ?? false
        }

        /// The shown browser's page painted content (Chromium's first contentful paint) or loaded.
        func pagePainted(_ services: AppServices) -> Bool {
            guard let browser else { return false }
            if case .finished = browser.tab.state.phase { return true }
            return services.cache.cef.benchMarks.firstPaints[browser.tab.id.rawValue] != nil
        }

        func changed(_ command: Command, _ now: Probe) -> Bool {
            switch command {
            case .newWorkspace: now.workspace != nil && now.workspace != workspace
            case .newTab, .newTerminal: now.pane == pane && now.tab != nil && now.tab != tab
            case .newBrowser: now.pane == pane && now.tab != nil && now.tab != tab && now.tab == now.selected
            case .splitRight, .splitDown: now.workspace == workspace && now.pane != pane && now.paneCount > paneCount
            case .linkRight, .splitBrowser, .dockRespawn: now.workspace == workspace && now.paneCount > paneCount
            }
        }

        func confirmed(_ command: Command) -> Bool {
            let realTab = tab.map { !$0.hasPrefix(ProvisionalTab.idPrefix) } ?? false
            switch command {
            case .newWorkspace, .newTab, .newTerminal, .newBrowser: return realTab
            case .splitRight, .splitDown, .linkRight, .splitBrowser, .dockRespawn: return realTab && (paneHandle ?? .max) < (1 << 62)
            }
        }
    }
}
#endif
