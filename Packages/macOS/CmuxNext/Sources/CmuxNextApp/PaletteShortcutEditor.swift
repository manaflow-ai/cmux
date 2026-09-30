import AppKit
import CmuxNextActions
import CmuxNextPalette
import CmuxNextSettings
import os

/// The palette's shortcut recorder writes through here: each change is one
/// `shortcuts.bindings.<id>` write to cmux.json (`CMUX_NEXT_CONFIG_FILE`
/// in test launches), which the settings watcher applies to the registry,
/// so every window, menu and the Settings editor follow. A failed write
/// reloads the file, so the optimistic registry change never outlives it.
@MainActor
final class PaletteShortcutEditor: PaletteShortcutEditing {
    private unowned let services: AppServices
    private let settings: SettingsController
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "shortcuts")

    init(services: AppServices, settings: SettingsController) {
        self.services = services
        self.settings = settings
    }

    /// The chord's meaning in a page (Chrome's table) and in a terminal
    /// (the user's Ghostty keybind for window, tab and split actions, named
    /// by the cmux action it runs).
    func environment(for event: NSEvent?) -> ShortcutEditEnvironment {
        let registry = services.registry
        let ghostty: String? = event.flatMap { event in
            services.keyRouter.ghosttyHostAction(event).flatMap(TerminalHostActionRoute.route).map { route in
                registry.descriptor(for: route.id)?.title ?? route.id.rawValue
            }
        }
        return ShortcutEditEnvironment(ghosttyBinding: { _ in ghostty }, chromeChords: BrowserChordTable.chromeReserved)
    }

    func save(_ changes: [ShortcutChange]) {
        write { settings in
            for change in changes { try await settings.setShortcut(change.shortcut, for: change.id) }
        }
    }

    func restoreDefault(_ id: ActionID, unbinding others: [ActionID]) {
        write { settings in
            try await settings.resetShortcut(for: id)
            for other in others { try await settings.setShortcut(nil, for: other) }
        }
    }

    private func write(_ body: @escaping @MainActor (SettingsController) async throws -> Void) {
        let settings = settings, logger = logger
        services.registry.track(Task { @MainActor in
            do {
                try await body(settings)
                return nil
            } catch {
                logger.error("shortcut write failed: \(String(describing: error), privacy: .public)")
                await settings.reload()
                return ActionWorkFailure("cmux.json write failed: \(error)")
            }
        })
    }
}
