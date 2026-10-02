import CmuxNextDesign

/// The pure focus transition function (plans/cmux-next/focus.md section 4):
/// `(state, event) -> (state, effects)`. No AppKit, no side effects; the
/// coordinator applies the effects after it returns.
nonisolated enum FocusReducer {
    static func reduce(_ state: FocusState, _ event: FocusEvent) -> (FocusState, [FocusEffect]) {
        var next = state
        var effects: [FocusEffect] = []
        var forceResponder = false
        var forceContext = false
        if next.drag != nil, overridesDrag(event) { next.drag?.overridden = true }

        switch event {
        case .topology(let topology):
            applyTopology(topology, to: &next, effects: &effects)
        case .focusPane(let pane, let workspace, let source):
            if source.isUserIntent { bump(&next) }
            if let workspace, workspace != next.topology.workspace {
                remember(pane, in: workspace, &next)
            } else if next.topology.contains(pane: pane) {
                next.pane = pane
                next.target = .content
                forceResponder = true
            }
        case .selectTab(let pane, let tab, let workspace, let source):
            if source.isUserIntent { bump(&next) }
            if let workspace, workspace != next.topology.workspace {
                effects.append(.select(pane: pane, tab: tab))
                remember(pane, in: workspace, &next)
            } else if !next.topology.contains(pane: pane) {
                // A pane this window does not show: remembered selection only.
                effects.append(.select(pane: pane, tab: tab))
            } else if next.topology.pane(pane)?.tab(tab) != nil {
                // Only a tab the pane holds (a stale CLI or menu request
                // named a tab that moved or closed: selecting it blanked
                // the pane; input-spec.md bug B1).
                effects.append(.select(pane: pane, tab: tab))
                next.topology.select(tab, in: pane)
                next.pane = pane
                next.target = .content
                forceResponder = true
            }
        case .focusTarget(let target, let source):
            if next.sidebarHidden, target.isSidebar { break }
            if source.isUserIntent { bump(&next) }
            if target == .addressBar || target == .findBar || target == .devTools {
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
        case .expect(let key, let target, let awayFrom, let generation):
            guard generation == next.generation else { break }
            next.expectation = FocusState.Expectation(key: key, target: target, awayFrom: awayFrom, generation: generation)
            land(&next, effects: &effects)
        case .dragBegan(let tabs, let pane):
            next.drag = FocusState.DragRestore(tabs: tabs, sourcePane: pane, pane: next.pane, target: next.target,
                                               tab: next.pane.flatMap { next.topology.pane($0)?.selected })
        case .dragEnded(let outcome):
            let restore = next.drag
            next.drag = nil
            switch outcome {
            case .cancelled:
                // Put back what the drag changed, unless the user chose
                // something newer meanwhile. Only a pane-scoped target can be
                // re-applied (the applier cannot put the responder back into
                // an arbitrary field), and chrome targets only on the same
                // tab (input-spec.md bug B6).
                if let restore, !restore.overridden, let pane = restore.pane, next.topology.contains(pane: pane) {
                    next.pane = pane
                    if restore.target.isPaneScoped {
                        let sameTab = next.topology.pane(pane)?.selected == restore.tab
                        next.target = sameTab ? restore.target : .content
                    }
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
            // Only a tab this window shows (F6: focus mode never names a
            // missing tab, not even until the next topology).
            guard let tab = tab ?? browserTab(of: next), next.topology.allTabIDs.contains(tab) else { break }
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
            state.pane = successor(of: pane, history: state.recentPanes, old: old, new: topology, policy: state.closeFocus)
            if state.target.isPaneScoped { state.target = .content }
        } else if state.pane == nil {
            state.pane = topology.panes.first?.id
        } else if let pane = state.pane, old.pane(pane)?.selected != topology.pane(pane)?.selected,
                  state.target == .addressBar || state.target == .findBar || state.target == .devTools {
            // Focus follows the selection; the old tab's chrome is gone.
            state.target = .content
        }
        // Closed (or moved away) panes leave the shown workspace's history.
        if let workspace = topology.workspace, let recent = state.history[workspace] {
            let kept = recent.filter(topology.contains(pane:))
            if kept.count != recent.count { state.history[workspace] = kept.isEmpty ? nil : kept }
        }
        let live = topology.allTabIDs
        for tab in state.browserFocusMode where !live.contains(tab) {
            state.browserFocusMode.remove(tab)
            effects.append(.browserFocusMode(tab: tab, active: false))
        }
        land(&state, effects: &effects)
    }

    /// The pane that takes focus after the focused `pane` left the
    /// topology (closed, moved away, removed by another client or the
    /// daemon): `FocusAfterClose.pane` over the columns of the screen that
    /// showed it (close-focus.md), so a successor on another (hidden)
    /// screen is chosen only when that screen has no pane left. Then the
    /// newest surviving pane in the history, else the first pane.
    static func successor(of pane: String, history: [String], old: FocusTopology, new: FocusTopology,
                          policy: CloseFocusPolicy) -> String? {
        let columns = old.columns(containing: pane) ?? [FocusTopology.Column(id: "", panes: old.panes.map(\.id))]
        let before = columns.map(\.panes)
        let after = columns.map { $0.panes.filter(new.contains(pane:)) }
        let onScreen = Set(before.flatMap { $0 })
        if let pick = FocusAfterClose.pane(focused: pane, before: before, after: after,
                                          history: history.filter(onScreen.contains), policy: policy),
           new.contains(pane: pick) {
            return pick
        }
        return history.first(where: new.contains(pane:)) ?? new.panes.first?.id
    }

    // MARK: Helpers

    /// `pane` is now the focused pane of `workspace`: restored on switching
    /// back, and newest in that workspace's history.
    private static func remember(_ pane: String, in workspace: String, _ state: inout FocusState) {
        state.remembered[workspace] = pane
        var recent = state.history[workspace] ?? []
        guard recent.first != pane else { return }
        recent.removeAll { $0 == pane }
        recent.insert(pane, at: 0)
        if recent.count > FocusState.historyLimit { recent.removeLast(recent.count - FocusState.historyLimit) }
        state.history[workspace] = recent
    }

    /// A user intent that did not come from the drag's own mouse events.
    private static func overridesDrag(_ event: FocusEvent) -> Bool {
        switch event {
        case .focusPane(_, _, let source), .selectTab(_, _, _, let source), .focusTarget(_, let source), .responder(_, let source):
            source.isUserIntent && source != .mouse
        case .beginIntent:
            true
        default:
            false
        }
    }

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
        case .devTools(let reported):
            guard state.topology.contains(pane: reported) else { return true }
            pane = reported
            target = .devTools
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
        case .browserPage(_, let tab), .addressBar(_, let tab), .findBar(_, let tab), .devTools(_, let tab): tab
        default: nil
        }
    }

    /// Diffs old and new state into the generic effects.
    private static func finish(from old: FocusState, to new: inout FocusState, effects: inout [FocusEffect],
                               forceResponder: Bool, forceContext: Bool) {
        // A chrome target exists only on a browser tab (an expectation or a
        // restore may name one on a tab that changed kind or closed; F4).
        if new.target == .addressBar || new.target == .findBar,
           new.pane.flatMap({ new.topology.pane($0)?.selectedTab?.kind }) != .browser {
            new.target = .content
        }
        if let workspace = new.topology.workspace, let pane = new.pane, new.topology.contains(pane: pane) {
            remember(pane, in: workspace, &new)
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
