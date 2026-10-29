#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import CmuxNextActions
import CmuxNextDaemon
import CmuxNextSettings

private typealias JSON = CmuxNextSettings.JSONValue

/// `debug.new_tab {action: "bench_create", command}` (DEBUG builds): the instant-create budget of
/// Cmd-N, Cmd-T, Ctrl-` (New Terminal Tab), Cmd-D, Cmd-Shift-D and Shift-Cmd-L (New Browser Tab),
/// each driven through the real key path (`debug.key`).
///
/// Per run it reports, in ms after the key:
/// - `key_ms`: the key's synchronous main-thread time (handler included);
/// - `visible_ms`: the first display frame at which the result shows (Cmd-N: the window shows
///   another workspace; Cmd-T, Ctrl-`: the focused pane shows another tab; Cmd-D / Cmd-Shift-D: the
///   window's focused pane is a new pane);
/// - `confirmed_ms`: the first frame at which the daemon's object replaced the provisional one
///   (no `pending_tab_` id, no provisional pane handle), or null within 5 s;
/// - `content_ms`: the first frame at which the new object shows its content: a terminal's shell
///   printed into its viewport (the prompt); null within 5 s, and for Cmd-N, Cmd-T (the New Tab
///   page) and `new_browser` (see `page_ms`);
/// - `frames_to_visible`: display frames from the key to `visible_ms` (1 = the next frame);
/// - `spans`: the main-thread spans and marks `BenchSpans` recorded (handler stages, daemon reply).
///
/// `new_browser` (PL-cef-tab, `scripts/cmux-next/cef-tab-bench.py`) is Cmd-Shift-L, or with `run` an action id,
/// that action run as a person's (with `url`: a link opened in a new tab; `openBrowser.webkit`):
/// visible once the pane shows the new tab selected (its themed pane; `chrome_ms`: its browser view in it); `page_ms` the
/// first frame after its page painted (first contentful paint, or its load ended); the spans
/// include Chromium's main-thread steps (`CEFBenchMarks`: `cef.create_window`, `cef.tab_add`, ...).
@MainActor
enum DebugInstantCreateBench {
    private static let frames = BenchFrames()

    enum Command: String, CaseIterable {
        /// Whether `content_ms` applies: a terminal's prompt (Cmd-N and Cmd-T show the New Tab page;
        /// a browser tab has `page_ms`).
        var showsContent: Bool { self == .newTerminal || self == .splitRight || self == .splitDown }

        case newWorkspace = "new_workspace", newTab = "new_tab", newTerminal = "new_terminal", splitRight = "split_right", splitDown = "split_down", newBrowser = "new_browser"

        var key: (String, [String]) {
            switch self {
            case .newWorkspace: ("n", ["command"])
            case .newTab: ("t", ["command"])
            case .newTerminal: ("`", ["control"])
            case .splitRight: ("d", ["command"])
            case .splitDown: ("d", ["command", "shift"])
            case .newBrowser: ("l", ["command", "shift"])
            }
        }
    }

    static func run(_ params: [String: CmuxNextSettings.JSONValue], _ controller: WindowController, _ services: AppServices) async -> CmuxNextSettings.JSONValue {
        guard let command = params["command"]?.stringValue.flatMap(Command.init(rawValue:)) else {
            return .object(["error": .string("command: one of \(Command.allCases.map(\.rawValue).joined(separator: ", "))")])
        }
        let before = Probe(controller)
        let (key, modifiers) = command.key
        frames.start()
        BenchSpans.begin()
        services.cache.cef.benchMarks.arm { name, milliseconds in BenchSpans.mark(name, milliseconds: milliseconds) }
        defer { services.cache.cef.benchMarks.arm(nil) }
        let start = ContinuousClock.now
        if let action = params["run"]?.stringValue {
            let arguments = params["url"]?.stringValue.map { ["url": ActionValue.string($0)] } ?? [:]
            _ = services.registry.perform(ActionID(rawValue: action), invocation: ActionInvocation(arguments: arguments))
        } else { _ = DebugKey.send(["key": .string(key), "modifiers": .array(modifiers.map(JSON.string)), "window": .string(controller.state.id)], services: services) }
        let keyMilliseconds = BenchSpans.ms(.now - start)
        let visible = await frames.settled(until: { before.changed(command, Probe(controller)) }, start: start, window: 0, deadline: 5_000)
        let chrome = visible == nil || command != .newBrowser ? nil : await frames.settled(until: { Probe(controller).browser != nil }, start: start, window: 0, deadline: 5_000)
        let page = visible == nil || command != .newBrowser ? nil
            : await frames.settled(until: { Probe(controller).pagePainted(services) }, start: start, window: 0, deadline: 5_000)
        let confirmed = visible == nil ? nil
            : await frames.settled(until: { Probe(controller).confirmed(command) }, start: start, window: 0, deadline: 5_000)
        let content = visible == nil || !command.showsContent ? nil
            : await frames.settled(until: { Probe.showsContent(command, controller, services) }, start: start, window: 0, deadline: 5_000)
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
            "content_ms": content.map { .number($0) } ?? .null,
            "frames_to_visible": visible.map { .number(($0 / refresh).rounded(.up)) } ?? .null,
            "main_thread_spans_ms": .number(spans.reduce(0) { $0 + $1.milliseconds }),
            "spans": .array(spans.map { .object(["name": .string($0.name), "at": .number($0.start), "ms": .number($0.milliseconds)]) }),
            "frames": stats,
        ])
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
            }
        }

        func confirmed(_ command: Command) -> Bool {
            let realTab = tab.map { !$0.hasPrefix(ProvisionalTab.idPrefix) } ?? false
            switch command {
            case .newWorkspace, .newTab, .newTerminal, .newBrowser: return realTab
            case .splitRight, .splitDown: return realTab && (paneHandle ?? .max) < (1 << 62)
            }
        }

        /// The focused pane's new terminal shows its content: its viewport has text (the shell's
        /// prompt).
        static func showsContent(_ command: Command, _ controller: WindowController, _ services: AppServices) -> Bool {
            guard let key = controller.content?.focusedPane?.currentTabKey else { return false }
            let text = services.cache.existingTerminal(key)?.session.surfaceView.viewportText() ?? ""
            return !text.allSatisfy(\.isWhitespace)
        }
    }
}
#endif
