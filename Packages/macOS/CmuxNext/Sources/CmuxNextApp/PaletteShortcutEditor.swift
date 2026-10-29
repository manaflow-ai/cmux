import struct CmuxSafeConcurrency.OwnerReference
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
    private let servicesReference: OwnerReference<AppServices>
    /// The app's services, which own this; nil (reported) only once they are gone.
    private var services: AppServices? { servicesReference.resolve() }
    private let settings: SettingsController
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "shortcuts")

    init(services: AppServices, settings: SettingsController) {
        servicesReference = OwnerReference(services: services)
        self.settings = settings
    }

    /// The chord's meaning in a page (`BrowserChordTable`) and in a terminal
    /// (the user's Ghostty keybind for window, tab and split actions, named
    /// by the cmux action it runs).
    func environment(for event: NSEvent?) -> ShortcutEditEnvironment {
        guard let services else {
            return ShortcutEditEnvironment(ghosttyBinding: { _ in nil }, chromeChords: BrowserChordTable.chromeReserved)
        }
        let registry = services.registry
        let ghostty: String? = event.flatMap { event in
            services.keyRouter.ghosttyBinding(for: event).map { id in registry.descriptor(for: id)?.title ?? id.rawValue }
        }
        return ShortcutEditEnvironment(ghosttyBinding: { _ in ghostty }, chromeChords: BrowserChordTable.chromeReserved)
    }

    func save(_ changes: [ShortcutChange]) {
        write { settings in
            for change in changes {
                if let keys = change.keys {
                    try await settings.setShortcuts(keys, for: change.id)
                } else {
                    try await settings.setShortcut(change.shortcut, for: change.id)
                }
            }
        }
    }

    func restoreDefault(_ id: ActionID, unbinding others: [ActionID]) {
        write { settings in
            try await settings.resetShortcut(for: id)
            for other in others { try await settings.setShortcut(nil, for: other) }
        }
    }

    private func write(_ body: @escaping @MainActor (SettingsController) async throws -> Void) {
        guard let services else { return }
        let settings = settings, logger = logger
        // main-hop-allow: the write is SettingsController's own main-actor async write (its file write runs off main); the task only starts it and reports a refusal
        services.registry.track(Task {
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
