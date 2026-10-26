// Energy Saver's session actions (plans/cmux-next/chrome-parity/p14-energy.md, D): "Turn Off Energy
// Saver for Now" and its undo. Chrome's battery saver bubble offers the same "Turn off for now"
// (chrome/browser/ui/views/performance_controls/battery_saver_bubble_view.cc), which calls
// `BatterySaverModeManager::SetTemporaryBatterySaverDisabledForSession`. No default shortcut.
// Titles live in Localizable.xcstrings.

nonisolated enum EnergyActionCatalog: ActionCatalogGroup {
    static func descriptors() -> [ActionDescriptor] {
        [
            action("energy.saver.turnOffForNow",
                   title: String(localized: "action.energy.saver.turnOffForNow", defaultValue: "Turn Off Energy Saver for Now",
                                 bundle: .module),
                   symbol: "leaf", keywords: keywords + ["off", "disable", "pause", "for now"],
                   cli: "settings turn-off-energy-saver-for-now"),
            action("energy.saver.turnOnNow",
                   title: String(localized: "action.energy.saver.turnOnNow", defaultValue: "Turn On Energy Saver Again",
                                 bundle: .module),
                   symbol: "leaf.fill", keywords: keywords + ["on", "enable", "resume", "again"],
                   cli: "settings turn-on-energy-saver-now"),
        ]
    }

    private static let keywords = ["energy", "saver", "battery", "power", "low power", "efficiency"]

    /// An app-wide palette action with a CLI verb. MCP leaves it out: when Energy Saver runs is the
    /// person's call, as the `energy.saver` setting is.
    private static func action(_ id: ActionID, title: String, symbol: String, keywords: [String], cli: String) -> ActionDescriptor {
        ActionDescriptor(id: id, title: title, keywords: keywords, category: .settings, symbol: symbol, surfaces: [.palette],
                         cliName: cli,
                         surfacePlan: ActionSurfacePlan(cli: .offered, contextMenuExemption: .noObject, mcpExemption: .systemChange))
    }
}
