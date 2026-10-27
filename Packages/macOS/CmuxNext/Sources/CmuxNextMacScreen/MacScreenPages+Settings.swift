public import CmuxNextActions
import CmuxNextCompat
public import CmuxNextSettings
import CmuxNextWakeups
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
            // main-hop-allow: the switch shows the value in this turn; setSetting is SettingsController's own main-actor async write
            Task {
                do { try await settings?.setSetting(descriptor, to: .bool(on), by: writer) } catch is SettingUserOnly {
                    refuse(String(describing: SettingUserOnly(key: descriptor.id, writer: writer)))
                } catch {}
            }
        }
        // Services, not views: the tap follows the setting whatever shows. `visible`: a cmux.json edit or the
        // CLI changes what the toolbar's menu and the home page's switch show; a person's change flushes as
        // the rest of their action.
        settingsFollows = [
            ServiceObservation(.visible, owner: "MacScreenPages.systemShortcuts", on: mainWork) {
                settings.snapshot.macScreen.systemShortcuts
            } apply: { [weak shortcuts] on in
                shortcuts?.enabled = on
            },
        ]
        #if DEBUG
        settingsFollows.append(ServiceObservation(.visible, owner: "MacScreenPages.relayOnly", on: mainWork) {
            settings.snapshot.macScreenDebug.relayOnly
        } apply: { [weak self] relayOnly in
            self?.relayOnly = relayOnly
        })
        #endif
    }

    /// Who is changing Send System Shortcuts to the Remote Mac from Mac
    /// Screen: an automation run's origin, else (a gesture in this app's UI) the user.
    public nonisolated static func systemShortcutsWriter(run: ActionRunScope?) -> SettingWriter {
        run.map { SettingWriter($0.origin) } ?? .user
    }
}
