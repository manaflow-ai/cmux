public import CmuxNextActions
import CmuxNextCompat
public import CmuxNextSettings
import Foundation

extension MacScreenPages {
    /// Keyboard > Mac Screen > Send System Shortcuts to the Remote Mac drives the
    /// system shortcut tap; the toolbar's menu item writes the same setting.
    /// DEV builds: Settings > Development > Relay Only drives every Mac Screen session.
    /// `refuse` reports a refused write (an automation run changing a user-only setting).
    public func follow(_ settings: SettingsController, refuse: @escaping @MainActor (String) -> Void) {
        let shortcuts = systemShortcuts
        shortcuts.setEnabled = { [weak settings] on in
            // The setting is user-only, the same writer check as Settings: any
            // in-app UI interaction (mouse, keyboard, accessibility press) is the
            // user; an automation run (CLI, agents, scripts, the socket) is refused.
            let writer = Self.systemShortcutsWriter(run: ActionRunScope.current)
            guard let descriptor = SettingsSchema.descriptor(for: MacScreenSettings.systemShortcutsPath) else { return }
            // task-owner: one settings write per menu or switch change
            Task {
                do { try await settings?.setSetting(descriptor, to: .bool(on), by: writer) } catch is SettingUserOnly {
                    refuse(String(describing: SettingUserOnly(key: descriptor.id, writer: writer)))
                } catch {}
            }
        }
        // task-owner: app-lifetime settings observation, made once at launch (AppDelegate); event-driven, holds the tap weakly
        Task { [weak shortcuts] in
            for await on in ObservationStream({ settings.snapshot.macScreen.systemShortcuts }) {
                shortcuts?.enabled = on
            }
        }
        #if DEBUG
        // task-owner: app-lifetime settings observation, made once at launch (AppDelegate); event-driven, holds the pages weakly
        Task { [weak self] in
            for await relayOnly in ObservationStream({ settings.snapshot.macScreenDebug.relayOnly }) {
                self?.relayOnly = relayOnly
            }
        }
        #endif
    }

    /// Who is changing Send System Shortcuts to the Remote Mac from Mac
    /// Screen: an automation run's origin, else (a gesture in this app's UI) the user.
    public nonisolated static func systemShortcutsWriter(run: ActionRunScope?) -> SettingWriter {
        run.map { SettingWriter($0.origin) } ?? .user
    }
}
