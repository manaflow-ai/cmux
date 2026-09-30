/// The pure focus transition function (plans/cmux-next/focus.md section 4):
/// `(state, event) -> (state, effects)`. No AppKit, no side effects; the
/// coordinator applies the effects after it returns.
nonisolated enum FocusReducer {
    static func reduce(_ state: FocusState, _ event: FocusEvent) -> (FocusState, [FocusEffect]) {
        var next = state
        var effects: [FocusEffect] = []
        var forceResponder = false
        var forceContext = false

        switch event {
        case .topology(let topology):
            applyTopology(topology, to: &next, effects: &effects)
        case .focusPane(let pane, let workspace, let source):
            if source.isUserIntent { bump(&next) }
            if let workspace, workspace != next.topology.workspace {
                next.remembered[workspace] = pane
            } else if next.topology.contains(pane: pane) {
                next.pane = pane
                next.target = .content
                forceResponder = true
            }
        case .selectTab(let pane, let tab, let workspace, let source):
            if source.isUserIntent { bump(&next) }
            effects.append(.select(pane: pane, tab: tab))
            if let workspace, workspace != next.topology.workspace {
                next.remembered[workspace] = pane
            } else if next.topology.pane(pane)?.tab(tab) != nil {
                next.topology.select(tab, in: pane)
                next.pane = pane
                next.target = .content
                forceResponder = true
            }
        case .focusTarget(let target, let source):
            if next.sidebarHidden, target.isSidebar { break }
            if source.isUserIntent { bump(&next) }
            if target == .addressBar || target == .findBar {
                guard let pane = next.pane, next.topology.pane(pane)?.selectedTab?.kind == .browser else { break }
            }
            next.target = target
            forceResponder = true
        case .responder(let responder, let source):
            guard next.overlays.isEmpty else { break }
            forceResponder = accept(responder, source: source, into: &next)
        case .windowKey(let key):
            next.windowKey = key
            forceResponder = key
            forceContext = key
        case .appActive(let active):
            next.appActive = active
        case .overlayOpened(let overlay):
            next.overlays.append(overlay)
        case .overlayClosed(let overlay):
            if let index = next.overlays.lastIndex(of: overlay) {
                next.overlays.remove(at: index)
                forceResponder = next.overlays.isEmpty
            }
        case .beginIntent:
            bump(&next)
        case .expect(let key, let target, let generation):
            guard generation == next.generation else { break }
            next.expectation = FocusState.Expectation(key: key, target: target, generation: generation)
            land(&next, effects: &effects)
        case .dragBegan(let tabs, let pane):
            next.drag = FocusState.DragRestore(tabs: tabs, sourcePane: pane, pane: next.pane, target: next.target)
        case .dragEnded(let outcome):
            let restore = next.drag
            next.drag = nil
            switch outcome {
            case .cancelled:
                if let pane = restore?.pane, next.topology.contains(pane: pane) {
                    next.pane = pane
                    next.target = restore?.target ?? .content
                }
                forceResponder = true
            case .dropped(let tabs, let awayFrom):
                bump(&next)
                if let tab = tabs.first {
                    next.expectation = FocusState.Expectation(key: .tab(tab), target: .content, awayFrom: awayFrom,
                                                              generation: next.generation)
                    land(&next, effects: &effects)
                }
            case .movedAway:
                break
            }
        case .contentPresented(let pane):
            forceResponder = pane == next.pane
        case .toggleBrowserFocusMode(let tab):
            guard let tab = tab ?? browserTab(of: next) else { break }
            if next.browserFocusMode.remove(tab) == nil { next.browserFocusMode.insert(tab) }
            effects.append(.browserFocusMode(tab: tab, active: next.browserFocusMode.contains(tab)))
        case .sidebarVisibility(let hidden):
            next.sidebarHidden = hidden
            if hidden, next.target.isSidebar {
                next.target = .content
                forceResponder = true
            }
        }

        finish(from: state, to: &next, effects: &effects, forceResponder: forceResponder, forceContext: forceContext)
        return (next, effects)
    }

    // MARK: Topology

    private static func applyTopology(_ topology: FocusTopology, to state: inout FocusState, effects: inout [FocusEffect]) {
        let old = state.topology
        state.topology = topology
        if old.workspace != topology.workspace {
            if let workspace = old.workspace, let pane = state.pane { state.remembered[workspace] = pane }
            state.pane = topology.workspace.flatMap { state.remembered[$0] }.flatMap { topology.contains(pane: $0) ? $0 : nil }
                ?? topology.panes.first?.id
            if state.target != .sidebar(keyboard: true) || state.sidebarHidden { state.target = .content }
            state.drag = nil
        } else if let pane = state.pane, !topology.contains(pane: pane) {
            state.pane = successor(of: pane, history: state.history, in: old.panes.map(\.id), surviving: topology)
                ?? topology.panes.first?.id
            if state.target.isPaneScoped { state.target = .content }
        } else if state.pane == nil {
            state.pane = topology.panes.first?.id
        } else if let pane = state.pane, old.pane(pane)?.selected != topology.pane(pane)?.selected,
                  state.target == .addressBar || state.target == .findBar {
            // Focus follows the selection; the old tab's chrome is gone.
            state.target = .content
        }
        let live = topology.allTabIDs
        for tab in state.browserFocusMode where !live.contains(tab) {
            state.browserFocusMode.remove(tab)
            effects.append(.browserFocusMode(tab: tab, active: false))
        }
        land(&state, effects: &effects)
    }

    /// The most recently focused surviving pane (closing a split you just
    /// made returns to where you were), else the next surviving pane after
    /// `pane` in the old layout order, else the previous one.
    /// Deterministic (never dictionary order).
    static func successor(of pane: String, history: [String], in oldOrder: [String], surviving topology: FocusTopology) -> String? {
        if let recent = history.first(where: { $0 != pane && topology.contains(pane: $0) }) { return recent }
        guard let index = oldOrder.firstIndex(of: pane) else { return nil }
        if let after = oldOrder[(index + 1)...].first(where: topology.contains(pane:)) { return after }
        return oldOrder[..<index].last(where: topology.contains(pane:))
    }

    // MARK: Helpers

    private static func bump(_ state: inout FocusState) {
        state.generation &+= 1
        state.expectation = nil
    }

    /// Lands the expectation when its tab exists and no newer intent
    /// happened since it was made.
    private static func land(_ state: inout FocusState, effects: inout [FocusEffect]) {
        guard let expectation = state.expectation else { return }
        guard expectation.generation == state.generation else {
            state.expectation = nil
            return
        }
        let location: (pane: String, tab: String)? = switch expectation.key {
        case .surface(let surface): state.topology.location(ofSurface: surface)
        case .tab(let tab): state.topology.location(ofTab: tab)
        }
        guard let location, location.pane != expectation.awayFrom else { return }
        state.expectation = nil
        if state.topology.pane(location.pane)?.selected != location.tab {
            state.topology.select(location.tab, in: location.pane)
        }
        effects.append(.select(pane: location.pane, tab: location.tab))
        state.pane = location.pane
        state.target = expectation.target
    }

    /// Accepts an AppKit responder change as the user's choice. Returns
    /// whether the responder must be re-applied (a view left the window).
    private static func accept(_ responder: FocusEvent.Responder, source: FocusEvent.Source, into state: inout FocusState) -> Bool {
        let target: FocusState.Target
        var pane = state.pane
        switch responder {
        case .windowOrNone:
            return true
        case .content(let reported):
            guard state.topology.contains(pane: reported) else { return true }
            pane = reported
            target = .content
        case .addressBar(let reported):
            guard state.topology.contains(pane: reported) else { return true }
            pane = reported
            target = .addressBar
        case .findBar(let reported):
            guard state.topology.contains(pane: reported) else { return true }
            pane = reported
            target = .findBar
        case .sidebar, .sidebarField:
            // A hidden sidebar cannot hold the keyboard: re-apply the target.
            guard !state.sidebarHidden else { return true }
            target = responder == .sidebar ? .sidebar(keyboard: source == .keyboard) : .sidebarField
        case .textField:
            target = .textField
        }
        guard pane != state.pane || target != state.target else { return false }
        if source.isUserIntent { bump(&state) }
        state.pane = pane
        state.target = target
        return false
    }

    private static func browserTab(of state: FocusState) -> String? {
        switch state.resolved {
        case .browserPage(_, let tab), .addressBar(_, let tab), .findBar(_, let tab): tab
        default: nil
        }
    }

    /// Diffs old and new state into the generic effects.
    private static func finish(from old: FocusState, to new: inout FocusState, effects: inout [FocusEffect],
                               forceResponder: Bool, forceContext: Bool) {
        if let workspace = new.topology.workspace, let pane = new.pane, new.topology.contains(pane: pane) {
            new.remembered[workspace] = pane
            if new.history.first != pane {
                new.history.removeAll { $0 == pane }
                new.history.insert(pane, at: 0)
                if new.history.count > FocusState.historyLimit { new.history.removeLast() }
            }
        }
        if let pane = new.pane, pane != old.pane || forceResponder, new.topology.contains(pane: pane) {
            effects.append(.revealPane(pane))
        }
        let resolved = new.resolved
        if resolved != old.resolved || forceResponder {
            effects.append(.moveResponder(resolved))
        }
        if new.context != old.context || forceContext {
            effects.append(.publishContext(new.context))
        }
    }
}
