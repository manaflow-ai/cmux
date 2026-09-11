import CmuxSettings
import CmuxSettingsUI
import Foundation

/// The executable's construction boundary for device preferences, discovery, and Settings actions.
@MainActor
struct MacDevicesComposition {
    let defaultsStore: UserDefaultsSettingsStore
    let registry: DeviceSurfaceProviderRegistry
    let computers: HiveComputersService
    let settingsActions: ComputersSettingsActions

    init(defaults: UserDefaults, catalog: SettingCatalog) {
        let store = UserDefaultsSettingsStore(defaults: defaults, migrating: catalog.all)
        let preferences = DevicesPreferencesModel(store: store)
        preferences.start()
        let registry = DeviceSurfaceProviderRegistry(
            preferences: preferences,
            makeAutomaticClient: { identity, teamID in
                MobileHostIrxRuntime.shared.makeDeviceClient(identity: identity, teamID: teamID)
            },
            allowsAutomaticConnections: {
                MobileHostIrxRuntime.isEnabled && ManagedIrohNetworkingPolicy.isEnabled
            }
        )
        let computers = HiveComputersService(registry: registry, openSidebar: { instance in
            AppDelegate.shared?.openDevicesSidebarAndReveal(instance: instance, registry: registry)
        })
        self.defaultsStore = store
        self.registry = registry
        self.computers = computers
        self.settingsActions = ComputersSettingsActions(
            updates: { computers.updates() },
            refresh: { await computers.refresh() },
            pair: { await computers.pair($0) },
            open: { await computers.open($0) },
            unpair: { await computers.unpair($0) },
            setDiscoveryEnabled: { await preferences.setDiscoveryEnabled($0) },
            setIncomingAccessEnabled: { await preferences.setIncomingAccessEnabled($0) },
            setHidden: { id, hidden in
                guard let instance = SurfaceDeviceInstanceID(wireValue: id) else { return }
                await preferences.setHidden(instance, hidden: hidden)
            },
            showPairing: { MobilePairingWindowController.shared.show() }
        )
    }
}
