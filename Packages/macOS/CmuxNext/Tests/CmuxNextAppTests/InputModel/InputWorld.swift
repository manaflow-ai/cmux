@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextBrowser
import CmuxNextDaemon
import Foundation

/// The composed input system under test (plans/cmux-next/input-spec.md
/// section 6): a simulated daemon tree, AppKit key window, first responders,
/// frame-deferred content presentation, Chromium child windows and the
/// palette and sheets, driving the REAL reducers and runners: one
/// `FocusCoordinator` per window (FIFO queue, echo suppression), the
/// omnibar reducer per browser tab, a `TerminalAttachMachine` per terminal
/// view, and the `KeyRouter` tier rules. `SimWindow` stands in for
/// `FocusEffectApplier` and follows its rules line by line.
final class InputWorld {
    struct DTab: Hashable {
        var id: String
        var kind: FocusTopology.Kind
        var surface: String { "s-\(id)" }
        /// Browser tabs alternate engines: Chromium pages live in a child window.
        var isChromium: Bool { kind == .browser && (Int(id.dropFirst()) ?? 0) % 2 == 0 }
    }

    struct DPane: Hashable {
        var id: String
        var tabs: [DTab]
    }

    /// What has the keyboard at the AppKit level.
    enum KeyHolder: Hashable {
        case none
        case window(Int)
        /// The Chromium page window of `pane` in cmux window `window`.
        case childPage(Int, pane: String)
        case palette
        case sheet(Int)
        case groupEditor(Int)
    }

    /// A daemon change or command response that arrives later.
    enum Pending: Hashable {
        case delta(Change)
        case response(window: Int, key: FocusState.Expectation.Key, target: FocusState.Target, generation: UInt64)
    }

    enum Change: Hashable {
        case newTab(workspace: String, pane: String, tab: DTab)
        case closeTab(String)
        case split(workspace: String, after: String, pane: String, tab: DTab)
        case closePane(String)
        case move(tab: String, to: String)
        /// A drop into a new split: the pane is created holding the tab.
        case moveToNewPane(tab: String, workspace: String, after: String, pane: String)
    }

    struct Terminal {
        var machine = TerminalAttachMachine<Int>(initialSize: CellSize(cols: 80, rows: 24))
        var oracle = AttachOracle<Int>()
        var nextLink = 1
    }

    var workspaces: [String: [DPane]] = [:]
    let workspaceOrder = ["w1", "w2", "w3", "w4"]
    var windows: [SimWindow] = []
    var key: KeyHolder = .none
    /// `WindowManager.lastActive`.
    var lastActive: Int?
    /// `WindowManager.active`: the key window's, else the last active one.
    var active: Int? {
        if case .window(let index) = key { return index }
        return lastActive ?? (windows.isEmpty ? nil : 0)
    }
    var appActive = true
    var paletteOpen = false
    /// Where the keyboard returns when the palette closes (its parent).
    var paletteReturn: KeyHolder = .none
    /// The cmux window the palette panel belongs to (never a page window).
    var paletteOwner: Int? {
        switch paletteReturn {
        case .window(let index), .childPage(let index, _): index
        default: nil
        }
    }
    var sheetReturn: [Int: KeyHolder] = [:]
    var context = FocusState.Context()
    var pending: [Pending] = []
    var hiddenTabs: Set<String> = []
    var drag: (window: Int, pane: String, tab: String)?
    var terminals: [String: Terminal] = [:]
    var omnibars: [String: OmnibarState] = [:]
    /// AppKit reports a first-responder view leaving the window through
    /// `makeFirstResponder` (true) or silently (false). Both are checked.
    let reportsRemoval: Bool
    var violations: [InputViolation] = []
    var nextID = 100
    var chunk: UInt8 = 0
    var stats = Stats()

    struct Stats {
        var steps = 0
        var worldChecks = 0
        var typedToTerminal = 0
        var typedLost = 0
    }

    init(windows count: Int, reportsRemoval: Bool) {
        self.reportsRemoval = reportsRemoval
        workspaces["w1"] = [DPane(id: "p1", tabs: [DTab(id: "t1", kind: .terminal), DTab(id: "t2", kind: .browser)]),
                            DPane(id: "p2", tabs: [DTab(id: "t3", kind: .terminal)])]
        workspaces["w2"] = [DPane(id: "p3", tabs: [DTab(id: "t4", kind: .browser), DTab(id: "t5", kind: .terminal)])]
        workspaces["w3"] = [DPane(id: "p4", tabs: [DTab(id: "t6", kind: .terminal)]),
                            DPane(id: "p5", tabs: [DTab(id: "t7", kind: .browser)])]
        workspaces["w4"] = [DPane(id: "p6", tabs: [DTab(id: "t8", kind: .browser)])]
        for index in 0..<count {
            let window = SimWindow(world: self, index: index, workspace: workspaceOrder[index % workspaceOrder.count])
            windows.append(window)
        }
        for (index, window) in windows.enumerated() {
            window.workspace = workspaceOrder[index]
            window.focus.send(.appActive(true))
            window.refresh()
            window.focus.send(.contentPresented(pane: window.focus.state.pane ?? ""))
        }
        setKey(.window(0))
        frame()
    }

    // MARK: Daemon

    func panes(_ workspace: String) -> [DPane] {
        (workspaces[workspace] ?? []).map { pane in DPane(id: pane.id, tabs: pane.tabs.filter { !hiddenTabs.contains($0.id) }) }
    }

    func workspace(ofPane pane: String) -> String? {
        workspaces.first { $0.value.contains { $0.id == pane } }?.key
    }

    func tab(_ id: String) -> DTab? {
        workspaces.values.flatMap { $0.flatMap(\.tabs) }.first { $0.id == id }
    }

    func makeID(_ prefix: String) -> String {
        nextID += 1
        return "\(prefix)\(nextID)"
    }

    /// Applies a daemon change and tells every window showing it.
    func apply(_ change: Change) {
        var touched: Set<String> = []
        func edit(_ workspace: String, _ body: (inout [DPane]) -> Void) {
            guard var panes = workspaces[workspace] else { return }
            body(&panes)
            workspaces[workspace] = panes
            touched.insert(workspace)
        }
        switch change {
        case .newTab(let workspace, let pane, let tab):
            edit(workspace) { panes in panes.firstIndex { $0.id == pane }.map { panes[$0].tabs.append(tab) } }
        case .closeTab(let id):
            hiddenTabs.remove(id)
            for workspace in workspaceOrder {
                edit(workspace) { panes in
                    for index in panes.indices { panes[index].tabs.removeAll { $0.id == id } }
                    panes.removeAll { $0.tabs.isEmpty }
                }
            }
            closeTerminal(id)
        case .split(let workspace, let after, let pane, let tab):
            edit(workspace) { panes in
                let index = panes.firstIndex { $0.id == after }.map { $0 + 1 } ?? panes.count
                panes.insert(DPane(id: pane, tabs: [tab]), at: index)
            }
        case .closePane(let id):
            guard let workspace = workspace(ofPane: id), (workspaces[workspace]?.count ?? 0) > 1 else { return }
            let closed = workspaces[workspace]?.first { $0.id == id }?.tabs ?? []
            edit(workspace) { $0.removeAll { $0.id == id } }
            closed.forEach { closeTerminal($0.id) }
        case .move(let id, let target):
            guard let moved = tab(id), let workspace = workspace(ofPane: target) else { return }
            for source in workspaceOrder { edit(source) { panes in for i in panes.indices { panes[i].tabs.removeAll { $0.id == id } } } }
            edit(workspace) { panes in panes.firstIndex { $0.id == target }.map { panes[$0].tabs.append(moved) } }
            for source in workspaceOrder { edit(source) { $0.removeAll { $0.tabs.isEmpty } } }
        case .moveToNewPane(let id, let workspace, let after, let pane):
            guard let moved = tab(id) else { return }
            for source in workspaceOrder { edit(source) { panes in for i in panes.indices { panes[i].tabs.removeAll { $0.id == id } } } }
            edit(workspace) { panes in
                let index = panes.firstIndex { $0.id == after }.map { $0 + 1 } ?? panes.count
                panes.insert(DPane(id: pane, tabs: [moved]), at: index)
            }
            for source in workspaceOrder { edit(source) { $0.removeAll { $0.tabs.isEmpty } } }
        }
        for window in windows where touched.contains(window.workspace) { window.refresh() }
    }

    // MARK: Key window

    /// Moves AppKit key status, with the notifications AppKit sends:
    /// resign on the old window first, then become on the new one.
    func setKey(_ new: KeyHolder, byClick: Bool = false) {
        let old = key
        guard old != new else { return }
        key = new
        // `PaletteController`: the palette closes when it resigns key (a
        // click elsewhere) and reports it at once; the clicked window keeps
        // the keys.
        if old == .palette, paletteOpen { closePaletteOverlay() }
        switch old {
        case .window(let index):
            windows[index].focus.send(.windowKey(false))
        case .groupEditor(let index):
            // The bubble dismisses when it resigns key.
            windows[index].focus.send(.overlayClosed(.groupEditor))
        default:
            break
        }
        switch new {
        case .window(let index):
            lastActive = index
            windows[index].focus.send(.windowKey(true))
        case .childPage(let index, let pane):
            // `FocusEffectApplier.childWindowDidBecomeKey`: the page window of
            // `pane` has the keys; the parent keeps no responder, becomes the
            // active window and publishes its context.
            // A click chooses the page; any other key change re-applies the model.
            let window = windows[index]
            guard let page = window.presented[pane], tab(page)?.isChromium == true else { break }
            lastActive = index
            context = window.focus.state.context
            window.childPage = page
            window.focus.responderDidChange(byClick ? .content(pane: pane) : .windowOrNone, source: byClick ? .mouse : .programmatic)
            if window.responder != .windowOrNone {
                window.setResponder(.windowOrNone, reported: true, source: byClick ? .mouse : .programmatic)
            }
            context = window.focus.state.context
        case .groupEditor(let index):
            windows[index].focus.send(.overlayOpened(.groupEditor))
        default:
            break
        }
        // A window owned by a cmux window (sheet, panel) makes that window
        // the active one, and it publishes its context
        // (`FocusEffectApplier.ownedWindowDidBecomeKey`).
        let owner: Int? = switch new {
        case .sheet(let index), .groupEditor(let index): index
        case .palette: paletteOwner
        default: nil
        }
        if let owner {
            lastActive = owner
            context = windows[owner].focus.state.context
        }
    }

    func closePaletteOverlay() {
        paletteOpen = false
        for window in windows where window.focus.state.overlays.contains(.palette) { window.focus.send(.overlayClosed(.palette)) }
    }

    // MARK: Terminals

    func terminal(_ tab: String) -> Terminal? { terminals[tab] }

    func startTerminal(_ tab: String) {
        guard terminals[tab] == nil else { return }
        terminals[tab] = Terminal()
        reduceTerminal(tab, .start)
    }

    func closeTerminal(_ tab: String) {
        guard terminals[tab] != nil else { return }
        reduceTerminal(tab, .close)
    }

    func reduceTerminal(_ tab: String, _ event: TerminalAttachMachine<Int>.Event) {
        guard var terminal = terminals[tab] else { return }
        let before = terminal.machine
        let effects = terminal.machine.reduce(event)
        violations += terminal.oracle.observe(event, before: before, after: terminal.machine, effects: effects, surface: tab)
        terminals[tab] = terminal
    }

    func type(into tab: String) {
        chunk &+= 1
        reduceTerminal(tab, .input(Data([chunk, chunk &+ 1])))
    }

    // MARK: Omnibar

    /// Sends `input` to the omnibar of `tab` and routes its effects like
    /// `BrowserChromeView.omnibarEvent`: commit, open and cancel hand the
    /// keyboard back to the page through the coordinator.
    func omnibar(_ tab: String, _ input: OmnibarInput, window: SimWindow, pane: String) {
        let state = omnibars[tab] ?? OmnibarState(pageURL: URL(string: "https://example.com/\(tab)"))
        let transition = OmnibarReducer.reduce(state, input, resolver: OmniboxResolver())
        omnibars[tab] = transition.state
        for case .ended(let reason) in transition.effects {
            switch reason {
            case .commit, .open, .cancel: window.focus.send(.focusPane(pane, source: .keyboard))
            case .blur: break
            }
        }
    }

    // MARK: Frames

    /// One display frame: every pane whose selection changed shows it.
    func frame() {
        for window in windows { window.present() }
    }

    var isSettled: Bool { windows.allSatisfy { $0.needsPresent.isEmpty } }
}
