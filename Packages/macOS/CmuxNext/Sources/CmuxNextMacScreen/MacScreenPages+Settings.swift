public import CmuxNextActions
import CmuxNextCompat
public import CmuxNextSettings
public import CmuxScreenKit
import Foundation

extension MacScreenPages {
    /// Keyboard > Mac Screen > Send System Shortcuts to the Remote Mac drives the
    /// system shortcut tap; the toolbar's menu item writes the same setting.
    /// cmux Remote > Screen Sharing Profile sets what each Mac Screen session's offer asks for.
    /// cmux Remote > Screen Sharing Quality, Frame Rate Limit and Bitrate Limit set where a new session starts.
    /// DEV builds: Settings > Development > Relay Only drives every Mac Screen session.
    /// Settings > Devices > Only Your Click Starts Viewing a Screen drives `onlyPersonStartsViewing`.
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
        // Only Your Click Starts Viewing a Screen: read now, so no automation open before the first change misses it.
        let (onlyPerson, laterOnlyPerson) = ObservationStream.current({ settings.snapshot.macScreen.onlyPersonStartsViewing })
        onlyPersonStartsViewing = onlyPerson
        // task-owner: app-lifetime settings observation, made once at launch (AppDelegate); event-driven, holds the pages weakly
        Task { [weak self] in
            for await on in laterOnlyPerson { self?.onlyPersonStartsViewing = on }
        }
        // task-owner: app-lifetime settings observation, made once at launch (AppDelegate); event-driven, holds the pages weakly
        Task { [weak self] in
            for await profile in ObservationStream({ settings.snapshot.remote.screenSharingProfile }) {
                self?.encodeProfile = Self.encodeProfile(profile)
            }
        }
        // remoteDesktop.* defaults: read now, so a tab restored at launch starts at them, not at Auto.
        let (defaults, laterDefaults) = ObservationStream.current({ settings.snapshot.remoteDesktop })
        defaultPreferences = Self.preferences(defaults)
        maxFpsCap = defaults.maxFps
        // task-owner: app-lifetime settings observation, made once at launch (AppDelegate); event-driven, holds the pages weakly
        Task { [weak self] in
            for await defaults in laterDefaults {
                self?.defaultPreferences = Self.preferences(defaults)
                self?.maxFpsCap = defaults.maxFps
            }
        }
        // task-owner: app-lifetime settings observation, made once at launch (AppDelegate); event-driven, holds nothing
        Task {
            for await on in ObservationStream({ settings.snapshot.macScreen.shareWithoutAsking }) {
                CmuxRemoteShareConsent.forgetUnlessOn(settingOn: on)
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

    /// The offer's `a=cmux-rd-encode-profile:` value for a Screen Sharing Profile: `ultra` for
    /// Ultra; nil for Balanced, which sends no line (the host's standard profile, as before).
    public nonisolated static func encodeProfile(_ profile: ScreenSharingProfile) -> String? {
        switch profile {
        case .balanced: nil
        case .ultra: profile.rawValue
        }
    }

    /// The toolbar picks a new session starts at from the `remoteDesktop.*` defaults: the quality preset as the
    /// toolbar's quality (Sharp Text is the display's full size, Smooth Motion 1920 wide at the display's rate,
    /// Low Bandwidth 1280 wide) and the bitrate limit as Customize's bitrate cap (`a=cmux-rd-max-kbps`).
    public nonisolated static func preferences(_ defaults: RemoteDesktopDefaults) -> ScreenPreferences {
        var preferences = ScreenPreferences()
        preferences.quality = switch defaults.quality {
        case .auto: .auto
        case .sharpText: .high
        case .smoothMotion: .smooth
        case .lowBandwidth: .low
        }
        preferences.maxKbps = defaults.maxKbps
        return preferences
    }

    /// Who is changing Send System Shortcuts to the Remote Mac from Mac
    /// Screen: an automation run's origin, else (a gesture in this app's UI) the user.
    public nonisolated static func systemShortcutsWriter(run: ActionRunScope?) -> SettingWriter {
        run.map { SettingWriter($0.origin) } ?? .user
    }
}
