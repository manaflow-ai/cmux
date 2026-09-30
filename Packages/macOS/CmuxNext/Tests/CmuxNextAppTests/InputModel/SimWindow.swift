@testable import CmuxNextApp
import CmuxNextBridge

/// One simulated cmux window: its real `FocusCoordinator`, the AppKit side
/// (first responder, Chromium page focus, layout focus) and the content
/// panes (strip selection, frame-deferred presentation). `apply` follows
/// `FocusEffectApplier`; `refresh` and `present` follow `PaneController`
/// (`apply`, `applySelection`, `showSelected`) and `WorkspaceContentController`.
final class SimWindow: FocusEffectApplying {
    unowned let world: InputWorld
    let index: Int
    let id: String
    let focus = FocusCoordinator()
    var workspace: String
    var selection = TabSelectionMemory()
    /// `stripModel.selectedID` per pane (may name a tab the pane lacks).
    var stripSelected: [String: String] = [:]
    /// `currentTabKey` per pane: what the pane shows now.
    var presented: [String: String] = [:]
    var needsPresent: Set<String> = []
    /// AppKit's first responder, classified.
    var responder: FocusEvent.Responder = .windowOrNone
    /// The page the applier gave Chromium focus to.
    var childPage: String?
    var layoutFocus: String?
    var hasSheet = false

    init(world: InputWorld, index: Int, workspace: String) {
        self.world = world
        self.index = index
        id = "W\(index)"
        self.workspace = workspace
        focus.applier = self
        focus.observer = { [unowned self] observation in
            guard case .reduced(let event, let before, let after) = observation else { return }
            self.world.violations += InputInvariants.step(from: before, event, to: after, window: self.id)
        }
    }

    // MARK: Topology (PaneController.apply, WorkspaceContentController.sendTopology)

    func topology() -> FocusTopology {
        FocusTopology(workspace: workspace, panes: world.panes(workspace).map { pane in
            FocusTopology.Pane(id: pane.id, tabs: pane.tabs.map { FocusTopology.Tab(id: $0.id, surface: $0.surface, kind: $0.kind) },
                               selected: stripSelected[pane.id])
        })
    }

    /// The daemon tree of this window's workspace changed.
    func refresh() {
        let panes = world.panes(workspace)
        let live = Set(panes.map(\.id))
        for pane in Array(presented.keys) where !live.contains(pane) {
            // The pane's view left the window with its content.
            let tab = presented.removeValue(forKey: pane)
            responderLeft(pane: pane, tab: tab)
            if let tab, childPage == tab { leaveChildPage() }
        }
        for pane in Array(stripSelected.keys) where !live.contains(pane) { stripSelected.removeValue(forKey: pane) }
        needsPresent.formIntersection(live)
        // LayoutModel.apply replaces a removed focused pane silently.
        if let layoutFocus, !live.contains(layoutFocus) { self.layoutFocus = panes.first?.id }
        for pane in panes {
            let selected = selection.resolve(pane: pane.id, tabs: pane.tabs.map(\.id), defaultIndex: 0)
            if stripSelected[pane.id] != selected { stripSelected[pane.id] = selected }
            if presented[pane.id] != selected { needsPresent.insert(pane.id) }
        }
        focus.send(.topology(topology()))
    }

    /// Frame-deferred `showSelected` for every pane that needs it.
    func present() {
        let panes = needsPresent.sorted()
        needsPresent.removeAll()
        for pane in panes { show(pane) }
    }

    /// `PaneController.showSelected`: swaps the content view, then tells
    /// the coordinator the pane's content exists.
    func show(_ pane: String) {
        let key = stripSelected[pane]
        let old = presented[pane]
        // `currentTabKey` changes first, then the old content view leaves.
        presented[pane] = key
        if old != key {
            responderLeft(pane: pane, tab: old)
            if let old, old == childPage { leaveChildPage() }
        }
        if let key, world.tab(key)?.kind == .terminal { world.startTerminal(key) }
        focus.send(.contentPresented(pane: pane))
    }

    /// A Chromium page window hid (its tab is no longer shown). The applier
    /// still references the page until it blurs it; the parent gets the
    /// keys back if the page window had them.
    private func leaveChildPage() {
        if case .childPage(index, _) = world.key { world.setKey(.window(index)) }
    }

    // MARK: AppKit

    /// The first responder's view left the window with `pane`'s content
    /// (`tab`): a field being edited ends editing, and AppKit makes the
    /// window first responder, reported or silently.
    func responderLeft(pane: String, tab: String?) {
        guard responder.pane == pane else { return }
        if case .addressBar = responder, let tab { world.omnibar(tab, .focusLost, window: self, pane: pane) }
        responder = .windowOrNone
        if world.reportsRemoval { focus.responderDidChange(.windowOrNone, source: .programmatic) }
    }

    /// Moves the first responder; `reported` when AppKit calls
    /// `ShellWindow.makeFirstResponder` (the coordinator then hears it,
    /// or drops it as an echo while effects run).
    func setResponder(_ new: FocusEvent.Responder, reported: Bool, source: FocusEvent.Source) {
        let old = responder
        responder = new
        if old != new, case .addressBar(let pane) = old, let tab = presented[pane] {
            world.omnibar(tab, .focusLost, window: self, pane: pane)
        }
        if old != new, case .addressBar(let pane) = new, let tab = presented[pane] {
            world.omnibar(tab, .focusGained(source == .mouse ? .mouse : .keyboard), window: self, pane: pane)
        }
        if reported { focus.responderDidChange(new, source: source) }
    }

    var isKey: Bool { world.key == .window(index) }

    // MARK: FocusEffectApplying (FocusEffectApplier)

    func apply(_ effects: [FocusEffect], state: FocusState) {
        for effect in effects {
            switch effect {
            case .select(let pane, let tab):
                if world.panes(workspace).contains(where: { $0.id == pane }) {
                    // `PaneController.applySelection`: selects and shows now.
                    guard stripSelected[pane] != tab || presented[pane] != tab else { continue }
                    selection.select(tab, in: pane)
                    stripSelected[pane] = tab
                    needsPresent.remove(pane)
                    show(pane)
                } else {
                    selection.select(tab, in: pane)
                }
            case .revealPane(let pane):
                layoutFocus = pane
            case .moveResponder(let resolved):
                moveResponder(resolved)
            case .publishContext(let context):
                if world.active == index { world.context = context }
            case .browserFocusMode:
                break
            }
        }
    }

    private func moveResponder(_ resolved: FocusState.Resolved) {
        switch resolved {
        case .terminal(let pane, let tab):
            guard presented[pane] == tab else { return }
            blurChildPage()
            if responder != .content(pane: pane) { setResponder(.content(pane: pane), reported: true, source: .programmatic) }
        case .browserPage(let pane, let tab):
            guard presented[pane] == tab else { return }
            if world.tab(tab)?.isChromium == true {
                if responder != .windowOrNone { setResponder(.windowOrNone, reported: true, source: .programmatic) }
                guard childPage != tab else { return }
                blurChildPage()
                childPage = tab
            } else {
                blurChildPage()
                if responder != .content(pane: pane) { setResponder(.content(pane: pane), reported: true, source: .programmatic) }
            }
        case .addressBar(let pane, let tab):
            guard presented[pane] == tab else { return }
            blurChildPage()
            if responder != .addressBar(pane: pane) { setResponder(.addressBar(pane: pane), reported: true, source: .programmatic) }
        case .findBar(let pane, let tab):
            guard presented[pane] == tab else { return }
            blurChildPage()
            if responder != .findBar(pane: pane) { setResponder(.findBar(pane: pane), reported: true, source: .programmatic) }
        case .emptyPane:
            blurChildPage()
            if responder.pane != nil { setResponder(.windowOrNone, reported: true, source: .programmatic) }
        case .sidebar, .sidebarField, .textField:
            blurChildPage()
        case .none:
            blurChildPage()
        case .overlay:
            break
        }
    }

    private func blurChildPage() {
        guard childPage != nil else { return }
        childPage = nil
        if case .childPage(index, _) = world.key { world.setKey(.window(index)) }
    }
}
