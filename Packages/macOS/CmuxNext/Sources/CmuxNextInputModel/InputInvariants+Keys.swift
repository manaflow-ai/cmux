// W10 of "something takes the keys" (plans/cmux-next/focus-invariant.md): pure, on an `InputObservation`, so the
// live monitor (`InputInvariants.world`) and tests check one definition.
nonisolated extension InputInvariants {
    /// W10 (plans/cmux-next/focus-invariant.md): something takes the keys. While cmux is the active app and shows
    /// a window, AppKit has a key window (a cmux window, its page, a panel, a sheet or Settings); and the key cmux
    /// window's model targets something that takes keys: not nothing, and not an empty pane while a pane of the
    /// window holds tabs. A top page or an open overlay has the keys of its own (W5, W6 check them). W1 then checks
    /// that AppKit's responder is that target.
    public static func keysHaveTarget(_ observation: InputObservation) -> [InputViolation] {
        var out: [InputViolation] = []
        let shown = observation.windows.filter { $0.visible == true }
        if observation.appActive == true, case .none = observation.keyWindow, !shown.isEmpty {
            out.append(InputViolation(invariant: .keysHaveTarget, window: observation.activeWindow,
                                      detail: "cmux is active with \(shown.count) window(s) shown and no key window: keys go nowhere"))
        }
        guard case .window(let id) = observation.keyWindow, let window = observation.window(id),
              window.topPage != true, window.model.overlays.isEmpty else { return out }
        switch window.model.resolved {
        case .none:
            out.append(InputViolation(invariant: .keysHaveTarget, window: id,
                                      detail: "the key window's model targets nothing (target \(window.model.target), \(window.model.topology.panes.count) panes)"))
        // An empty pane that holds no tab while another pane holds some: focus should have moved to a pane with
        // content (a pane loading its tab, or one whose tab shows no content kind, is not this case).
        case .emptyPane(let pane) where window.model.topology.pane(pane)?.tabs.isEmpty != false
            && window.model.topology.panes.contains(where: { !$0.tabs.isEmpty }):
            out.append(InputViolation(invariant: .keysHaveTarget, window: id,
                                      detail: "the key window's focused pane \(pane) holds no tab while another pane holds tabs"))
        default:
            break
        }
        return out
    }
}
