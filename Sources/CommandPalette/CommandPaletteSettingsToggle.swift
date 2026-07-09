import CmuxCommandPalette
import Foundation
import CmuxSettings

extension MenuBarOnlySettings {
    static let legacyCommandPaletteUsageKey = "commandPalette.commandUsage.v1"
    static let legacyCommandPaletteMenuBarOnlyCommandId = "palette.toggleSetting.menuBarOnly"

    static func normalizeLegacyStoredPreference(defaults: UserDefaults = .standard) {
        guard defaults.object(forKey: menuBarOnlyKey) != nil,
              defaults.bool(forKey: menuBarOnlyKey),
              defaults.object(forKey: explicitEnableKey) == nil else { return }
        setEnabled(!legacyCommandPaletteOneShotLikelyEnabledMenuBarOnly(defaults: defaults), defaults: defaults)
    }

    static func legacyCommandPaletteOneShotLikelyEnabledMenuBarOnly(defaults: UserDefaults = .standard) -> Bool {
        guard let data = defaults.data(forKey: legacyCommandPaletteUsageKey) else { return false }
        guard let history = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return true }
        guard history.count == 1, let entry = history[legacyCommandPaletteMenuBarOnlyCommandId] else { return false }
        guard let usage = entry as? [String: Any] else { return true }
        guard (usage["useCount"] as? NSNumber)?.intValue == 1 else { return false }
        return ((usage["lastUsedAt"] as? NSNumber)?.doubleValue ?? 0) > 0
    }
}

extension ContentView {
    nonisolated static func commandPaletteSettingsToggleCommandContributions() -> [CommandPaletteCommandContribution] {
        let catalog = CommandPaletteSettingsToggleCatalog()
        return catalog.descriptors.map { descriptor in
            CommandPaletteCommandContribution(
                commandId: descriptor.commandId,
                title: { _ in descriptor.commandTitle(strings: catalog.toggleStrings) },
                subtitle: { _ in descriptor.commandSubtitle(strings: catalog.toggleStrings) },
                keywords: descriptor.keywords + ["settings", "toggle", descriptor.settingsKey],
                when: { _ in descriptor.isAvailable(.standard) }
            )
        }
    }

    func registerSettingsToggleCommandHandlers(_ registry: inout CommandPaletteHandlerRegistry) {
        let catalog = CommandPaletteSettingsToggleCatalog()
        for descriptor in catalog.descriptors {
            registry.register(commandId: descriptor.commandId) {
                descriptor.toggle()
            }
        }
    }
}
