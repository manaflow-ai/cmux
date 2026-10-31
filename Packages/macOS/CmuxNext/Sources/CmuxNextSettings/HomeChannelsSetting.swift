public import CmuxNextActions
import CmuxNextCompat
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
    /// selects Home (`HomeDock.followChannelsSetting`). A run that changes nothing (enable while on,
    /// disable while off) succeeds and writes nothing (hq-6d 2026-10-15). `unavailable` is the refusal
    /// while settings are not loaded. Also keeps the registry's `homeChannelsEnabled` fact current, so
    /// actions that need Channels (Open Channels) show only while it is on.
    @MainActor public func bind(into registry: ActionRegistry, settings: @escaping @MainActor () -> SettingsController?, unavailable: String) {
        for (id, on) in [("home.enableChannels", true), ("home.disableChannels", false)] as [(ActionID, Bool)] {
            registry.bind(id, invoke: { invocation in
                guard DesignSettings.shared.homeChannelsEnabled != on else { return } // already so
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
        // task-owner: the registry's life (one per app); event-driven (Observation)
        Task { [weak registry] in
            for await on in ObservationStream({ DesignSettings.shared.homeChannelsEnabled }) {
                guard let registry else { return }
                var context = registry.context
                if on { context.insert(.homeChannelsEnabled) } else { context.remove(.homeChannelsEnabled) }
                if context != registry.context { registry.context = context }
            }
        }
    }
}

extension CmuxConfigSnapshot {
    /// The `home.*` rows: attachment location, the Channels entry, the Chief pet, the messages server and the
    /// Chief's engine (read from `root` as it applies, ``homeChiefEngine``; here only its diagnostic); each toggle
    /// absent is off, and a value that is not a bool is off plus a diagnostic.
    mutating func takeHome(_ root: JSONValue) {
        if let diagnostic = HomeChiefEngineSetting.parse(root).1 { diagnostics.append(diagnostic) }
        take(HomeKeepLocationSetting.parse(root), \.homeKeepLocation)
        take(Self.parseLabsToggle(root, path: HomeChannelsSetting.configPath, fallback: false), \.homeChannelsEnabled)
        take(Self.parseLabsToggle(root, path: HomeChiefPetSetting.configPath, fallback: false), \.homeChiefPetEnabled)
        take(HomeChiefPetSetting.parseMascot(root), \.homeChiefPetMascot)
        take(HomeServerSetting.parse(root), \.homeServer)
        take(ChiefReactionSettings.parse(root), \.chiefReactions)
        take(HomeBubbleColorsSetting.parse(root), \.homeBubbleColors)
    }
}
