public import CmuxNextActions
import CmuxNextDesign
public import CmuxNextDesignTokens
public import CmuxNextSettings
import CmuxNextSidebar

/// The sidebar view menu's "Workspaces as Tabs": the one-line workspace list Leo asked for as a
/// first-class toggle (2026-10-21), so it writes `sidebar.workspacesAsTabs` and works in every
/// build. It shows on this turn and rolls back if the settings file refuses the write. Turning it
/// off also clears the Debug tunable, which would otherwise keep the list on.
@MainActor
public struct SidebarCompactListToggle {
    public static let id: ActionID = "sidebar.compactList.toggle"
    private let settings: @MainActor () -> SettingsController?
    private let store: TunableStore

    public init(settings: @escaping @MainActor () -> SettingsController?, store: TunableStore = .shared) {
        self.settings = settings
        self.store = store
    }

    public func bind(into registry: ActionRegistry) {
        let settings = settings, store = store
        let tunable = SidebarTunables.workspacesAsTabs
        registry.bindEffect(Self.id, unavailable: { nil }) { invocation in
            guard let controller = settings(),
                  let descriptor = SettingsSchema.descriptor(for: SidebarSectionsSetting.workspacesAsTabsPath) else { return .done }
            let on = !SidebarTunables.workspacesAsTabsOn
            let before = DesignSettings.shared.sidebarSections.workspacesAsTabs
            DesignSettings.shared.sidebarSections.workspacesAsTabs = on
            if !on, store.isActive, tunable.value(in: store) { store.reset([tunable.key]) }
            let writer = SettingWriter(invocation.origin)
            return .applied(result: {
                do {
                    try await controller.setSetting(descriptor, to: .bool(on), by: writer)
                    return .success([:])
                } catch {
                    DesignSettings.shared.sidebarSections.workspacesAsTabs = before
                    return .failure(ActionWorkFailure(String(describing: error)))
                }
            })
        }
        ActionTargetTitles.setState(Self.id, in: registry) { _ in SidebarTunables.workspacesAsTabsOn }
        ActionTargetTitles.setPaletteState(Self.id, in: registry) { SidebarTunables.workspacesAsTabsOn }
    }
}
