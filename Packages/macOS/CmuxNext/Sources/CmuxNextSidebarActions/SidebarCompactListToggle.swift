public import CmuxNextActions
public import CmuxNextDesignTokens
import CmuxNextSidebar

/// The existing one-line workspace prototype, discoverable beside the sidebar's view choices.
/// It keeps its DEV/NIGHTLY gate and off-by-default tunable; density and manual order are untouched.
@MainActor
public struct SidebarCompactListToggle {
    public static let id: ActionID = "sidebar.compactList.toggle"
    private let store: TunableStore

    public init(store: TunableStore = .shared) {
        self.store = store
    }

    public func bind(into registry: ActionRegistry) {
        let store = store
        let tunable = SidebarTunables.workspacesAsTabs
        let id = Self.id
        registry.bindEffect(id, unavailable: { nil }) { _ in
            guard store.isActive else { return .done }
            if tunable.value(in: store) { store.reset([tunable.key]) }
            else { store.set(tunable.key, .bool(true)) }
            return .done
        }
        ActionTargetTitles.setState(id, in: registry) { _ in tunable.value(in: store) }
        ActionTargetTitles.setPaletteState(id, in: registry) { tunable.value(in: store) }
        ActionTargetVisibility.hide(id, in: registry) { _ in !store.isActive }
    }
}
