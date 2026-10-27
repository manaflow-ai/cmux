public import CmuxNextCompat

// Memory Saver's modes (plans/cmux-next/chrome-parity/p07-memory.md, task 065): one palette action
// per `memory.saver` value, as Chrome's Performance settings offer Memory Saver off and its Moderate,
// Balanced and Maximum modes (chrome/browser/resources/settings/performance_page/memory_saver_card.ts).
// No default shortcut. Titles live in Localizable.xcstrings.

nonisolated enum MemorySaverActionCatalog: ActionCatalogGroup {
    static func descriptors() -> [ActionDescriptor] {
        MemorySaverMode.allCases.map(descriptor)
    }

    private static func descriptor(_ mode: MemorySaverMode) -> ActionDescriptor {
        let keywords = ["memory", "memory saver", "saver", "ram", "discard", "hibernate", "sleep", "performance"]
        return switch mode {
        case .off:
            make(mode, title: String(localized: "action.memory.saver.off", defaultValue: "Turn Off Memory Saver", bundle: .module),
                 symbol: "memorychip", keywords: keywords + ["off", "disable", "never"], cli: "settings turn-off-memory-saver")
        case .conservative:
            make(mode, title: String(localized: "action.memory.saver.conservative", defaultValue: "Use Moderate Memory Saver", bundle: .module),
                 symbol: "memorychip", keywords: keywords + ["moderate", "conservative", "longer"], cli: "settings use-moderate-memory-saver")
        case .medium:
            make(mode, title: String(localized: "action.memory.saver.medium", defaultValue: "Use Balanced Memory Saver", bundle: .module),
                 symbol: "memorychip.fill", keywords: keywords + ["balanced", "medium", "default"], cli: "settings use-balanced-memory-saver")
        case .aggressive:
            make(mode, title: String(localized: "action.memory.saver.aggressive", defaultValue: "Use Maximum Memory Saver", bundle: .module),
                 symbol: "memorychip.fill", keywords: keywords + ["maximum", "aggressive", "sooner"], cli: "settings use-maximum-memory-saver")
        }
    }

    /// An app-wide setting action the CLI offers too; MCP leaves it to `settings_set`, as the
    /// `browser.hibernation.*` actions do. Category `.settings`: the palette's "Settings and Help".
    private static func make(_ mode: MemorySaverMode, title: String, symbol: String, keywords: [String], cli: String) -> ActionDescriptor {
        ActionDescriptor(id: mode.actionID, title: title, keywords: keywords, category: .settings, symbol: symbol, surfaces: [.palette],
                         cliName: cli,
                         surfacePlan: ActionSurfacePlan(cli: .offered, contextMenuExemption: .noObject, mcpExemption: .systemChange))
    }
}

nonisolated extension MemorySaverMode {
    /// The palette action that sets `memory.saver` to this mode: `memory.saver.<mode>`.
    public var actionID: ActionID {
        ActionID(rawValue: "memory.saver.\(rawValue)")
    }
}
