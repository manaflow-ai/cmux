import CmuxNextActions
import CmuxNextDesign
import CmuxNextSettings
import os

/// Toggle Match Terminal Background (palette, CLI `sidebar
/// toggle-match-terminal-background`): flips `appearance.sidebarSurface`
/// between "same" (the sidebar takes the main pane's, the terminal's,
/// background) and "separate" (shaded apart). The config layer is the one
/// owner, so Settings > Sidebar Background shows the same choice.
enum MatchTerminalBackgroundToggle {
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.actions")
    static let path = SidebarSurfaceSetting.configPath

    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        registry.bind("palette.toggleMatchTerminalBackground", run: { invocation in
            guard let settings = context.services.settings else { throw ActionFailure(message: RefusalStrings.settingsNotLoaded) }
            try AppearanceHandlers.requireUnmanaged(path, context)
            let next: SidebarSurface = SidebarSurfaceSetting.effective(in: settings.snapshot) == .same ? .separate : .same
            let writer = SettingWriter(invocation.origin)
            // task-owner: one settings write; ends when cmux.json is written
            Task {
                guard let descriptor = SettingsSchema.descriptor(for: path) else { return }
                do { try await settings.setSetting(descriptor, to: .string(next.rawValue), by: writer) } catch {
                    logger.error("sidebar surface setting failed: \(String(describing: error), privacy: .public)")
                }
            }
        })
        ActionTargetTitles.setState("palette.toggleMatchTerminalBackground", in: registry) { _ in
            context.services.settings.map { SidebarSurfaceSetting.effective(in: $0.snapshot) == .same }
        }
    }
}
