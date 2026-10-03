// World invariants (W): the focus model against what AppKit, Ghostty,
// WebKit and Chromium actually show (plans/cmux-next/input-spec.md
// section 2.5). Valid only once effects and presentation settled; a pane
// whose selected content is not presented yet is reported as unsettled and
// its window's content checks are skipped.
extension InputInvariants {
    struct WorldResult: Hashable, Sendable, Codable {
        var violations: [InputViolation]
        /// Windows skipped because content was still being presented.
        var unsettled: [String]
    }

    static func world(_ observation: InputObservation) -> WorldResult {
        var out: [InputViolation] = []
        var unsettled: [String] = []
        for window in observation.windows {
            out += model(window.model, window: window.id)
            if isSettled(window) {
                out += content(window)
            } else {
                unsettled.append(window.id)
            }
        }
        out += keyWindow(observation)
        out += overlays(observation)
        out += context(observation)
        return WorldResult(violations: out, unsettled: unsettled)
    }

    /// The focused pane shows the tab the model targets.
    static func isSettled(_ window: InputObservation.Window) -> Bool {
        let resolved = window.model.underlying
        guard let pane = resolved.pane, let tab = resolved.tab else { return true }
        return window.presented[pane] == tab
    }

    /// W1-W4 for one settled window.
    private static func content(_ window: InputObservation.Window) -> [InputViolation] {
        var out: [InputViolation] = []
        func fail(_ invariant: InputInvariant, _ detail: String) {
            out.append(InputViolation(invariant: invariant, window: window.id, detail: detail))
        }
        let model = window.model
        if let pane = model.pane, window.layoutFocus != pane {
            fail(.layoutMatches, "layout \(window.layoutFocus ?? "nil") != model \(pane)")
        }
        for pane in model.topology.panes {
            guard let shown = window.presented[pane.id] else { continue }
            if let selected = pane.selected, pane.tab(selected) == nil {
                fail(.presentedMatchesSelection, "pane \(pane.id) selects \(selected), which it does not hold")
            } else if shown != pane.selected {
                fail(.presentedMatchesSelection, "pane \(pane.id) shows \(shown) but selects \(pane.selected ?? "nil")")
            }
        }
        let resolved = model.resolved
        let childPage: String? = if case .browserPage(_, let tab) = resolved, window.childWindowTabs.contains(tab) { tab } else { nil }
        if let expected = expectedResponder(resolved, childPage: childPage), expected != window.responder {
            fail(.responderMatches, "appkit \(describe(window.responder)) (\(window.responderClass ?? "nil")) != model \(resolved.kind)")
        }
        if case .emptyPane = resolved, window.responder.pane != nil {
            fail(.responderMatches, "appkit \(describe(window.responder)) inside a pane while the focused pane is empty")
        }
        if case .terminal(_, let tab) = resolved, window.isKey {
            if window.ghosttyFocused != [tab] { fail(.ghosttyMatches, "ghostty \(window.ghosttyFocused) != [\(tab)]") }
        } else if !window.ghosttyFocused.isEmpty {
            fail(.ghosttyMatches, "ghostty \(window.ghosttyFocused) while model is \(resolved.kind)\(window.isKey ? "" : ", window not key")")
        }
        // Under an overlay the applier leaves page focus alone (keys go to
        // the overlay); closing it re-applies.
        if model.overlays.isEmpty, window.childPage != childPage {
            fail(.chromiumMatches, "chromium page \(window.childPage ?? "nil") != model \(childPage ?? "nil")")
        }
        return out
    }

    private static func expectedResponder(_ resolved: FocusState.Resolved, childPage: String?) -> FocusEvent.Responder? {
        switch resolved {
        case .terminal(let pane, _): .content(pane: pane)
        // A Chromium page has the keys in its own window; this window keeps no responder.
        case .browserPage(let pane, _): childPage == nil ? .content(pane: pane) : .windowOrNone
        case .addressBar(let pane, _): .addressBar(pane: pane)
        case .findBar(let pane, _): .findBar(pane: pane)
        case .agentPage(let pane, _), .page(let pane, _): .content(pane: pane)
        // A docked DevTools has the keys in its own child window, like a page.
        case .devTools: .windowOrNone
        case .sidebar: .sidebar
        case .sidebarField: .sidebarField
        case .textField: .textField
        case .emptyPane, .overlay, .none: nil
        }
    }

    /// W5: exactly the window AppKit made key believes it has the keyboard,
    /// and whatever is key belongs to that window's target.
    private static func keyWindow(_ observation: InputObservation) -> [InputViolation] {
        var out: [InputViolation] = []
        func fail(_ window: String?, _ detail: String) {
            out.append(InputViolation(invariant: .keyWindowOwned, window: window, detail: detail))
        }
        let owner: String? = if case .window(let id) = observation.keyWindow { id } else { nil }
        for window in observation.windows where window.model.windowKey != (window.id == owner) {
            fail(window.id, "model windowKey \(window.model.windowKey) but AppKit key window is \(observation.keyWindow)")
        }
        switch observation.keyWindow {
        case .childPage(let id):
            guard let window = observation.window(id) else { break }
            let underlying = window.model.underlying
            // The page's window, or its docked DevTools window.
            let isChildPage: Bool = switch underlying {
            case .browserPage(_, let tab), .devTools(_, let tab): window.childWindowTabs.contains(tab)
            default: false
            }
            if !isChildPage, window.model.overlays.isEmpty {
                fail(id, "a Chromium page window has the keys while the model targets \(underlying.kind)")
            }
        case .panel(let id?, let kind):
            if observation.window(id)?.model.overlays.isEmpty == true {
                fail(id, "panel \(kind) has the keys but the window's overlay stack is empty")
            }
        case .panel(nil, let kind):
            if !observation.windows.contains(where: { !$0.model.overlays.isEmpty }) {
                fail(nil, "panel \(kind) has the keys but no window has an overlay")
            }
        case .sheet(let id):
            if observation.window(id)?.model.overlays.contains(.sheet) == false {
                fail(id, "a sheet has the keys but the window has no sheet overlay")
            }
        case .none, .window, .other:
            break
        }
        return out
    }

    /// W6: the palette and sheets agree with the overlay stacks.
    private static func overlays(_ observation: InputObservation) -> [InputViolation] {
        var out: [InputViolation] = []
        let palettes = observation.windows.filter { $0.model.overlays.contains(.palette) }.map(\.id)
        if observation.paletteOpen ? palettes.count != 1 : !palettes.isEmpty {
            out.append(InputViolation(invariant: .overlaysMatch, window: nil,
                                      detail: "palette open \(observation.paletteOpen), overlay in \(palettes)"))
        }
        for window in observation.windows where window.hasSheet != window.model.overlays.contains(.sheet) {
            out.append(InputViolation(invariant: .overlaysMatch, window: window.id,
                                      detail: "sheet attached \(window.hasSheet), overlay \(window.model.overlays)"))
        }
        return out
    }

    /// W7: menus, the palette and the registry context act on the window
    /// that owns the keyboard (itself, its Chromium page window, its panel
    /// or sheet), so that window is the active one and publishes.
    private static func context(_ observation: InputObservation) -> [InputViolation] {
        var out: [InputViolation] = []
        let owner: String? = switch observation.keyWindow {
        case .window(let id), .childPage(let id), .sheet(let id): id
        case .panel(let id, _): id
        case .none, .other: nil
        }
        if let owner, observation.activeWindow != owner {
            out.append(InputViolation(invariant: .contextMatches, window: owner,
                                      detail: "active window \(observation.activeWindow ?? "nil") while the keys go to \(owner)"))
        }
        if let publisher = (owner ?? observation.activeWindow).flatMap(observation.window), publisher.model.context != observation.context {
            out.append(InputViolation(invariant: .contextMatches, window: publisher.id,
                                      detail: "published \(observation.context) != model \(publisher.model.context)"))
        }
        return out
    }

    static func describe(_ responder: FocusEvent.Responder) -> String {
        switch responder {
        case .content(let pane): "content:\(pane)"
        case .addressBar(let pane): "addressBar:\(pane)"
        case .findBar(let pane): "findBar:\(pane)"
        case .devTools(let pane): "devTools:\(pane)"
        case .sidebar: "sidebar"
        case .sidebarField: "sidebarField"
        case .textField: "textField"
        case .windowOrNone: "windowOrNone"
        }
    }
}

extension FocusEvent.Responder {
    /// The pane a pane-scoped responder is in.
    nonisolated var pane: String? {
        switch self {
        case .content(let pane), .addressBar(let pane), .findBar(let pane), .devTools(let pane): pane
        default: nil
        }
    }
}
