import AppKit
import CmuxSettings
import Foundation

/// The agent turn rail as a preview: off by default, turned on for one
/// person by the Beta Features toggle (Settings, the command palette, or
/// `agentTurnRail.beta.enabled` in cmux.json). While off, no terminal
/// reserves the rail's gutter or tails a transcript for it, and
/// Cmd-Shift-Up/Down reach Ghostty's jump_to_prompt.
enum AgentTurnRailPreview {
    static let commandId = "palette.toggleSetting.agentTurnRail"

    nonisolated static func isOptedIn(defaults: UserDefaults = .standard) -> Bool {
        let key = BetaFeaturesCatalogSection().agentTurnRail
        guard defaults.object(forKey: key.userDefaultsKey) != nil else { return key.defaultValue }
        return defaults.bool(forKey: key.userDefaultsKey)
    }

    static let paletteToggle = CommandPaletteSettingToggleDescriptor(
        commandId: commandId,
        settingsKey: "betaFeatures.agentTurnRail",
        title: { String(localized: "settings.betaFeatures.agentTurnRail", defaultValue: "Agent Turn Rail") },
        sectionTitle: { String(localized: "settings.section.betaFeatures", defaultValue: "Beta Features") },
        keywords: ["agentTurnRail.beta.enabled", "agent", "turn", "rail", "prompt", "claude", "codex", "terminal", "preview", "beta"],
        defaultValue: BetaFeaturesCatalogSection().agentTurnRail.defaultValue,
        defaultsKey: BetaFeaturesCatalogSection().agentTurnRail.userDefaultsKey
    )

    @MainActor private static var observer: NSObjectProtocol?
    @MainActor private static var appliedValue = false

    /// Applies the setting to every live terminal whenever it changes, from
    /// Settings, the palette or cmux.json. Idempotent.
    @MainActor static func startApplyingChanges() {
        guard observer == nil else { return }
        appliedValue = isOptedIn()
        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                let value = isOptedIn()
                guard value != appliedValue else { return }
                appliedValue = value
                for surface in GhosttyApp.terminalSurfaceRegistry.allTerminalSurfaces() {
                    surface.hostedView.reconcileAgentTurnRail()
                }
            }
        }
    }
}
