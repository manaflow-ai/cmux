import AppKit
import CmuxNextCompat

// The live checks of `HoverCardCoordinator` (`debug.desync`).
extension HoverCardCoordinator {
    /// The single-card invariant, checked live in debug builds
    /// (`debug.desync`): at most one card window exists and shows, and it
    /// shows what the machine says.
    public func singleCardViolations() -> [String] {
        var bad: [String] = []
        let windows = HoverCardPanel.liveInstances.load(ordering: .relaxed)
        if windows > 1 { bad.append("\(windows) hover card windows exist") }
        let showing = panel?.isShowingCard == true
        if showing, machine.shownTarget == nil, owned == nil { bad.append("a card shows while the machine has none") }
        if owned != nil, machine.shownTarget != nil { bad.append("an owner's card and \(machine.shownTarget?.id.rawValue ?? "-") share the window") }
        if !showing, let shown = machine.shownTarget, panel?.isVisible != true { bad.append("the machine shows \(shown.id) but no card is on screen") }
        return bad
    }
}
