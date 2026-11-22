@testable import CmuxNextApp
import CmuxNextBrowser
import Foundation

// Each fuzz action as the real entrypoint performs it, in the order AppKit
// and the app deliver the pieces (local mouse monitor before the window's
// key change and the view's own responder change, and so on).
extension InputWorld {
    func window(_ index: Int) -> SimWindow { windows[index % windows.count] }

    func pane(_ index: Int, in window: SimWindow) -> DPane? {
        let panes = panes(window.workspace)
        return panes.isEmpty ? nil : panes[index % panes.count]
    }

    var allPanes: [(workspace: String, pane: DPane)] {
        workspaceOrder.flatMap { workspace in panes(workspace).map { (workspace, $0) } }
    }

    var allTabs: [DTab] { allPanes.flatMap(\.pane.tabs) }

    /// The window the keyboard goes to (a page window counts as its parent).
    var keyWindowIndex: Int? {
        switch key {
        case .window(let index), .childPage(let index, _): index
        default: nil
        }
    }

    func perform(_ action: FuzzAction) {
        stats.steps += 1
        switch action {
        case .daemonNewTab(let n, let browser):
            guard !allPanes.isEmpty else { return }
            let (workspace, pane) = allPanes[n % allPanes.count]
            apply(.newTab(workspace: workspace, pane: pane.id, tab: DTab(id: makeID("t"), kind: browser ? .browser : .terminal)))
        case .daemonCloseTab(let n):
            guard !allTabs.isEmpty else { return }
            apply(.closeTab(allTabs[n % allTabs.count].id))
        case .daemonSplit(let n, let browser):
            guard !allPanes.isEmpty else { return }
            let (workspace, pane) = allPanes[n % allPanes.count]
            apply(.split(workspace: workspace, after: pane.id, pane: makeID("p"), tab: DTab(id: makeID("t"), kind: browser ? .browser : .terminal)))
        case .daemonClosePane(let n):
            guard !allPanes.isEmpty else { return }
            apply(.closePane(allPanes[n % allPanes.count].pane.id))
        case .daemonMoveTab(let tab, let pane):
            guard !allTabs.isEmpty, !allPanes.isEmpty else { return }
            apply(.move(tab: allTabs[tab % allTabs.count].id, to: allPanes[pane % allPanes.count].pane.id))
        case .deliver(let n):
            guard !pending.isEmpty else { return }
            switch pending.remove(at: n % pending.count) {
            case .delta(let change): apply(change)
            case .response(let index, let key, let target, let generation):
                windows[index].focus.expect(key, target: target, generation: generation)
            }
        case .reject(let n):
            guard !pending.isEmpty else { return }
            if case .delta(.closeTab(let id)) = pending.remove(at: n % pending.count), hiddenTabs.remove(id) != nil {
                refreshWindows(showing: id)
            }
        case .userSplit(let w, let browser): userCreate(window(w), split: true, browser: browser)
        case .userNewTab(let w, let browser): userCreate(window(w), split: false, browser: browser)
        case .userCloseTab(let w):
            let window = window(w)
            guard let tab = window.focus.state.resolved.tab ?? focusedTab(window) else { return }
            hiddenTabs.insert(tab)
            refreshWindows(showing: tab)
            pending.append(.delta(.closeTab(tab)))
        case .userMoveTab(let w, let n):
            let window = window(w)
            guard let source = window.focus.state.pane, let tab = focusedTab(window),
                  let target = pane(n, in: window)?.id, target != source else { return }
            window.focus.followMovedTab(tab, from: source)
            pending.append(.delta(.move(tab: tab, to: target)))
        case .clickPane(let w, let n):
            clickPane(window(w), n)
        case .pageTakesKey(let w, let n, let placed, let parented):
            let window = window(w)
            guard !window.hasSheet, let pane = pane(n, in: window),
                  window.presented[pane.id].flatMap(tab)?.isChromium == true else { return }
            setKey(.childPage(window.index, pane: pane.id), placed: placed, parented: parented)
        case .clickTab(let w, let n, let m):
            let window = window(w)
            guard !window.hasSheet, let pane = pane(n, in: window), !pane.tabs.isEmpty else { return }
            window.focus.send(.focusPane(pane.id, source: .mouse))
            setKey(.window(window.index))
            window.focus.send(.selectTab(pane: pane.id, tab: pane.tabs[m % pane.tabs.count].id, source: .mouse))
        case .clickSidebar(let w, let field):
            let window = window(w)
            guard !window.hasSheet else { return }
            setKey(.window(window.index))
            window.setResponder(field ? .sidebarField : .sidebar, reported: true, source: .mouse)
        case .otherTextField(let w):
            let window = window(w)
            guard !window.hasSheet else { return }
            setKey(.window(window.index))
            window.setResponder(.textField, reported: true, source: .mouse)
        case .keyNav(let w, let n):
            guard let window = keyed(w), KeyRouter.allows(.navigation, focus: window.focus.state),
                  let pane = pane(n, in: window) else { return }
            window.focus.send(.focusPane(pane.id, source: .keyboard))
        case .cmdL(let w):
            guard let window = keyed(w), KeyRouter.allows(.navigation, focus: window.focus.state) else { return }
            window.focus.send(.focusTarget(.addressBar, source: .keyboard))
        case .find(let w):
            guard let window = keyed(w), KeyRouter.allows(.content, focus: window.focus.state), window.focus.state.context.browser else { return }
            window.focus.send(.focusTarget(.findBar, source: .keyboard))
        case .escape(let w):
            guard let window = keyed(w) else { return }
            switch window.responder {
            case .addressBar(let pane): if let tab = window.presented[pane] { omnibar(tab, .key(.escape), window: window, pane: pane) }
            case .findBar(let pane): window.focus.send(.focusPane(pane, source: .keyboard))
            default: break
            }
        case .enter(let w):
            guard let window = keyed(w), case .addressBar(let pane) = window.responder, let tab = window.presented[pane] else { return }
            omnibar(tab, .key(.enter(.currentTab)), window: window, pane: pane)
        case .type:
            typeKeys()
        case .cliFocusPane(let w, let n):
            let window = window(w)
            guard let pane = pane(n, in: window) else { return }
            window.focus.send(.focusPane(pane.id, source: .cli))
        case .cliSelectTab(let w, let n, let stale):
            let window = window(w)
            let tabs = panes(window.workspace).flatMap(\.tabs)
            guard !tabs.isEmpty else { return }
            let tab = tabs[n % tabs.count].id
            let paneID = stale.flatMap { pane($0, in: window)?.id } ?? panes(window.workspace).first { $0.tabs.contains { $0.id == tab } }?.id
            guard let paneID else { return }
            // `AppCompatFrontend.selectTab`.
            window.selection.select(tab, in: paneID)
            window.focus.send(.selectTab(pane: paneID, tab: tab, workspace: window.workspace, source: .cli))
        case .keyWindow(let w):
            // A click on a window with a sheet gives the sheet the keys.
            let window = window(w)
            setKey(window.hasSheet ? .sheet(window.index) : .window(window.index))
        case .appActive(let on):
            guard on != appActive else { return }
            appActive = on
            windows.forEach { $0.focus.send(.appActive(on)) }
            if on, let active { setKey(windows[active].hasSheet ? .sheet(active) : .window(active)) } else if !on { setKey(.none) }
        case .openPalette:
            guard !paletteOpen, !isSheetKey, let active else { return }
            paletteOpen = true
            // `PaletteController`: the panel takes the keys only while the
            // app is active (a CLI request or a no-activate run never takes
            // the keyboard from the user's frontmost app).
            paletteReturn = appActive ? key : .window(active)
            windows[active].focus.send(.overlayOpened(.palette))
            if appActive { setKey(.palette) }
        case .closePalette:
            guard paletteOpen else { return }
            let hadKey = key == .palette
            closePaletteOverlay()
            if hadKey { setKey(paletteOwner.map { .window($0) } ?? .none) }
        case .paletteFocusPane(let n):
            guard paletteOpen, let active, let pane = pane(n, in: windows[active]) else { return }
            windows[active].focus.send(.focusPane(pane.id, source: .palette))
        case .openSheet(let w):
            let window = window(w)
            guard !paletteOpen, !window.hasSheet, keyWindowIndex == window.index else { return }
            window.hasSheet = true
            sheetReturn[window.index] = key
            window.focus.send(.overlayOpened(.sheet))
            setKey(.sheet(window.index))
        case .closeSheet(let w):
            let window = window(w)
            guard window.hasSheet else { return }
            window.hasSheet = false
            if fault != .sheetCloseUnreported { window.focus.send(.overlayClosed(.sheet)) }
            if key == .sheet(window.index) { setKey(.window(window.index)) }
        case .openGroupEditor(let w):
            let window = window(w)
            guard !paletteOpen, !window.hasSheet, keyWindowIndex == window.index else { return }
            openGroupEditor(window)
        case .closeGroupEditor:
            guard case .groupEditor(let index) = key else { return }
            closeGroupEditor(windows[index])
        case .switchWorkspace(let w):
            switchWorkspace(window(w))
        case .dragBegin(let w):
            let window = window(w)
            guard drag == nil, let pane = window.focus.state.pane, let tab = window.stripSelected[pane],
                  panes(window.workspace).first(where: { $0.id == pane })?.tabs.contains(where: { $0.id == tab }) == true else { return }
            drag = (window.index, pane, tab)
            window.focus.send(.dragBegan(tabs: [tab], pane: pane))
        case .dragEnd(let kind, let target):
            endDrag(kind: kind, target: target)
        case .focusMode(let w):
            guard let window = keyed(w) else { return }
            window.focus.send(.toggleBrowserFocusMode(tab: nil))
        case .frame:
            frame()
        case .attach(let n, let event):
            attach(n, event)
        }
    }

    // MARK: Pieces

    var isSheetKey: Bool { if case .sheet = key { true } else { false } }

    /// The window `w` when it has the keyboard (keys only reach that one).
    func keyed(_ w: Int) -> SimWindow? {
        guard let index = keyWindowIndex, index == w % windows.count else { return nil }
        return windows[index]
    }

    func focusedTab(_ window: SimWindow) -> String? {
        guard let pane = window.focus.state.pane, let tab = window.stripSelected[pane],
              panes(window.workspace).first(where: { $0.id == pane })?.tabs.contains(where: { $0.id == tab }) == true else { return nil }
        return tab
    }

    func refreshWindows(showing tab: String) {
        guard let workspace = workspaceOrder.first(where: { workspaces[$0]?.contains { $0.tabs.contains { $0.id == tab } } == true }) else { return }
        for window in windows where window.workspace == workspace { window.refresh() }
    }

    /// Split or new tab: the intent now, the daemon delta and the command
    /// response later, in either order (`expectFocus` after `beginIntent`).
    private func userCreate(_ window: SimWindow, split: Bool, browser: Bool) {
        guard let pane = window.focus.state.pane ?? panes(window.workspace).first?.id else { return }
        let generation = window.focus.beginIntent()
        let tab = DTab(id: makeID("t"), kind: browser ? .browser : .terminal)
        pending.append(.delta(split ? .split(workspace: window.workspace, after: pane, pane: makeID("p"), tab: tab)
                                    : .newTab(workspace: window.workspace, pane: pane, tab: tab)))
        pending.append(.response(window: window.index, key: .surface(tab.surface), target: browser ? .addressBar : .content,
                                 generation: generation))
    }

    /// A mouse-down in a pane. A Chromium page lives in its own window: the
    /// click makes that window key (`childWindowDidBecomeKey`) and the
    /// layout's monitor never sees it. Anything else: the layout's local
    /// monitor focuses the pane, the window becomes key, then the view's
    /// own `mouseDown` takes the first responder.
    private func clickPane(_ window: SimWindow, _ n: Int) {
        guard !window.hasSheet, let pane = pane(n, in: window) else { return }
        let shown = window.presented[pane.id].flatMap(tab)
        if let shown, shown.isChromium {
            setKey(.childPage(window.index, pane: pane.id), byClick: true)
            return
        }
        window.focus.send(.focusPane(pane.id, source: .mouse))
        setKey(.window(window.index))
        if shown != nil { window.setResponder(.content(pane: pane.id), reported: true, source: .mouse) }
    }

    /// Raw typing goes wherever AppKit sends keys.
    private func typeKeys() {
        guard let index = keyWindowIndex else { return }
        let window = windows[index]
        if case .childPage = key { return }
        if window.childPage != nil, window.responder == .windowOrNone { return }
        switch window.responder {
        case .content(let pane):
            guard let tab = window.presented[pane], self.tab(tab)?.kind == .terminal else { return }
            stats.typedToTerminal += 1
            type(into: tab)
        case .addressBar(let pane):
            guard let tab = window.presented[pane] else { return }
            let text = (omnibars[tab]?.fieldText ?? "") + "a"
            let end = NSRange(location: (text as NSString).length, length: 0)
            omnibar(tab, .fieldChanged(.init(text: text, selection: end), .insert), window: window, pane: pane)
        case .windowOrNone:
            stats.typedLost += 1
        default:
            break
        }
    }

    private func switchWorkspace(_ window: SimWindow) {
        let shown = Set(windows.map(\.workspace))
        guard let next = workspaceOrder.first(where: { !shown.contains($0) }) else { return }
        // `WindowController.install`: the old content leaves first.
        let old = window.presented
        window.presented.removeAll()
        if let pane = window.responder.pane { window.responderLeft(pane: pane, tab: old[pane]) }
        if case .childPage(window.index, _) = key { setKey(.window(window.index)) }
        window.workspace = next
        window.stripSelected.removeAll()
        window.needsPresent.removeAll()
        window.layoutFocus = nil
        // `WindowController.install`: topology, then re-apply focus.
        window.refresh()
        if let pane = window.focus.state.pane { window.focus.send(.contentPresented(pane: pane)) }
    }

    private func endDrag(kind: Int, target: Int) {
        guard let (index, source, tab) = drag else { return }
        drag = nil
        let window = windows[index]
        let others = panes(window.workspace).filter { $0.id != source }
        switch kind % 5 {
        case 1 where !others.isEmpty:
            window.focus.send(.dragEnded(.dropped(tabs: [tab], awayFrom: source)))
            pending.append(.delta(.move(tab: tab, to: others[target % others.count].id)))
        case 2:
            window.focus.send(.dragEnded(.dropped(tabs: [tab], awayFrom: source)))
            pending.append(.delta(.moveToNewPane(tab: tab, workspace: window.workspace, after: source, pane: makeID("p"))))
        case 3 where windows.count > 1:
            let drop = windows[(index + 1 + target % (windows.count - 1)) % windows.count]
            guard let pane = drop.focus.state.pane ?? panes(drop.workspace).first?.id else {
                window.focus.send(.dragEnded(.cancelled))
                return
            }
            window.focus.send(.dragEnded(.movedAway))
            drop.focus.send(.dragEnded(.dropped(tabs: [tab], awayFrom: source)))
            pending.append(.delta(.move(tab: tab, to: pane)))
        case 4:
            window.focus.send(.dragEnded(.dropped(tabs: [tab])))
        default:
            window.focus.send(.dragEnded(.cancelled))
        }
    }
}
