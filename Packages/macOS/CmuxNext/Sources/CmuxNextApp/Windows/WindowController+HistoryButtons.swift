import AppKit
import CmuxNextActions
import CmuxNextHistory

/// The titlebar band's Back and Forward (R69): a click runs
/// focusHistoryBack / focusHistoryForward, the right-click or long-press list
/// runs `history.goTo {index}`, and each button is enabled only while the
/// shown page's history or the trail has somewhere to go (history.md 4.2b).
extension WindowController {
    func installHistoryButtons() {
        let band = root.toolbarBand
        let registry = services.registry
        band.onHistory = { [weak registry] direction in
            _ = registry?.perform(direction == .back ? "focusHistoryBack" : "focusHistoryForward", invocation: ActionInvocation(origin: .user))
        }
        band.historyMenu = { [weak services, weak registry] direction in
            guard let items = services?.locationTrail.list(direction), !items.isEmpty else { return nil }
            return TitlebarHistoryMenu.make(items) { index in
                _ = registry?.perform("history.goTo", invocation: ActionInvocation(arguments: ["index": .int(index)], origin: .user))
            }
        }
        band.describeHistory(back: registry.descriptor(for: "focusHistoryBack")?.title ?? "",
                             forward: registry.descriptor(for: "focusHistoryForward")?.title ?? "")
        // Each window listens for itself; windowWillClose removes it.
        band.historyObserver = services.locationTrail.addObserver { [weak self] in self?.refreshHistoryButtons() }
        refreshHistoryButtons()
    }

    /// Stops listening to the trail (the window closes).
    func removeHistoryObserver() {
        guard let token = root.toolbarBand.historyObserver else { return }
        services.locationTrail.removeObserver(token)
        root.toolbarBand.historyObserver = nil
    }

    /// Re-reads whether Back and Forward have somewhere to go.
    func refreshHistoryButtons() {
        let trail = services.locationTrail
        root.toolbarBand.setHistoryEnabled(back: trail.canNavigate(.back, in: self), forward: trail.canNavigate(.forward, in: self))
    }
}
