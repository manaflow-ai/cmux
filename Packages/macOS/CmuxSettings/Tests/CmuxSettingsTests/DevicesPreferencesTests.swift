import Foundation
import Testing
@testable import CmuxSettings

@Suite("Device discovery and visibility preferences")
struct DevicesPreferencesTests {
    @Test("Fresh installs discover Macs without advertising this Mac")
    func privateByDefault() async throws {
        let name = "cmux.devices.defaults.\(UUID().uuidString)"
        let store = UserDefaultsSettingsStore(defaults: try #require(UserDefaults(suiteName: name)))
        let keys = DevicesCatalogSection()
        #expect(await store.value(for: keys.discoveryEnabled))
        #expect(await store.value(for: keys.incomingAccessEnabled) == false)
        await store.set(true, for: keys.incomingAccessEnabled)
        let restored = UserDefaultsSettingsStore(defaults: try #require(UserDefaults(suiteName: name)))
        #expect(await restored.value(for: keys.incomingAccessEnabled))
    }

    @Test("Discovery and incoming access can be changed independently")
    func independentControls() async throws {
        let name = "cmux.devices.preferences.\(UUID().uuidString)"
        let store = UserDefaultsSettingsStore(defaults: try #require(UserDefaults(suiteName: name)))
        let keys = DevicesCatalogSection()
        await store.set(true, for: keys.incomingAccessEnabled)
        await store.set(false, for: keys.discoveryEnabled)
        #expect(await store.value(for: keys.incomingAccessEnabled))
        await store.set(false, for: keys.incomingAccessEnabled)
        await store.set(true, for: keys.discoveryEnabled)
        #expect(await store.value(for: keys.discoveryEnabled))
        #expect(await store.value(for: keys.incomingAccessEnabled) == false)
    }

    @Test("Hiding concurrent Macs preserves both choices and survives reopening the store")
    func hideAndRestore() async throws {
        let name = "cmux.devices.visibility.\(UUID().uuidString)"
        let store = UserDefaultsSettingsStore(defaults: try #require(UserDefaults(suiteName: name)))
        let first = UUID().uuidString
        let second = UUID().uuidString
        async let hideFirst: Void = store.setMacHidden(deviceID: first, hidden: true)
        async let hideSecond: Void = store.setMacHidden(deviceID: second, hidden: true)
        _ = await (hideFirst, hideSecond)
        let restored = UserDefaultsSettingsStore(defaults: try #require(UserDefaults(suiteName: name)))
        let key = DevicesCatalogSection().hiddenMacIDs
        #expect(Set(await restored.value(for: key)) == Set([first.lowercased(), second.lowercased()]))
        await restored.setMacHidden(deviceID: "invalid", hidden: true)
        await restored.setMacHidden(deviceID: first.lowercased(), hidden: false)
        #expect(await restored.value(for: key) == [second.lowercased()])
    }
}
