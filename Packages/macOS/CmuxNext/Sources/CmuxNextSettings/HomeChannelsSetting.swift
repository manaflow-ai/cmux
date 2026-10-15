public import CmuxNextActions
import CmuxNextDesign

/// `home.channelsEnabled` in cmux.json (hq-6d cx-frn2y; Lawrence 2026-10-15: "u have to cmd shift p to
/// enable channels in the first place"): the sidebar shows the Channels entry (hq-ec's Channels page of
/// Home) right after Home. Off by default; the palette's Enable Channels and Disable Channels write it
/// (`home.enableChannels`, `home.disableChannels`). Disabling it while Channels shows selects Home.
public nonisolated struct HomeChannelsSetting {
    public nonisolated init() {}
    public static let configPath = ["home", "channelsEnabled"]
}

extension HomeChannelsSetting {
    /// Enable Channels and Disable Channels (`home.enableChannels`, `home.disableChannels`; the palette, the
    /// CLI and MCP): write `home.channelsEnabled` as the caller (an agent may: it is looks only). The
    /// sidebar's Channels entry follows the applied setting; turned off while Channels shows, the dock
    /// selects Home (`HomeDock.followChannelsSetting`). The palette lists the one that changes something.
    /// `unavailable` is the refusal while settings are not loaded.
    @MainActor public func bind(into registry: ActionRegistry, settings: @escaping @MainActor () -> SettingsController?, unavailable: String) {
        for (id, on) in [("home.enableChannels", true), ("home.disableChannels", false)] as [(ActionID, Bool)] {
            registry.bind(id, isEnabled: { DesignSettings.shared.homeChannelsEnabled != on }, invoke: { invocation in
                guard let settings = settings() else { return registry.refuse(unavailable) }
                let writer = SettingWriter(invocation.origin)
                registry.track(ActionWork {
                    do { try await settings.setSetting(at: Self.configPath, to: .bool(on), by: writer) } catch {
                        return ActionWorkFailure(refusal: .unavailable, reason: String(describing: error))
                    }
                    return nil
                })
            })
        }
    }
}

extension CmuxConfigSnapshot {
    /// The `home.*` rows: attachment location and the Channels entry; each absent is off, and a value
    /// that is not a bool is off plus a diagnostic.
    mutating func takeHome(_ root: JSONValue) {
        take(HomeKeepLocationSetting.parse(root), \.homeKeepLocation)
        take(Self.parseLabsToggle(root, path: HomeChannelsSetting.configPath, fallback: false), \.homeChannelsEnabled)
    }
}
