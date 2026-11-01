import CmuxNextActions
import CmuxNextDesign
import CmuxNextSettings
import CmuxNextSidebar

/// The existing one-line workspace prototype, discoverable beside the sidebar's view choices.
/// It keeps its DEV/NIGHTLY gate and off-by-default tunable; density and manual order are untouched.
enum SidebarCompactListToggle {
    static let id: ActionID = "sidebar.compactList.toggle"

    static func bind(into registry: ActionRegistry, store: TunableStore = .shared) {
        let tunable = SidebarTunables.workspacesAsTabs
        registry.bind(id, unavailable: { nil }) { _ in
            guard store.isActive else { return }
            if tunable.value(in: store) { store.reset([tunable.key]) }
            else { store.set(tunable.key, .bool(true)) }
        }
        ActionTargetTitles.setState(id, in: registry) { _ in tunable.value(in: store) }
        ActionTargetTitles.setPaletteState(id, in: registry) { tunable.value(in: store) }
        ActionTargetVisibility.hide(id, in: registry) { _ in !store.isActive }
    }
}
