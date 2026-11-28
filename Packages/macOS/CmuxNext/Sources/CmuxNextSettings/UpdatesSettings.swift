// The paths, defaults, ranges and the choice enums (UpdatesChannelSetting, UpdatesAutomaticSetting, UpdatesMeteredSetting,
// UpdatesNotifySetting, UpdatesWebSetting)
// are generated from schemas/settings/source/updates.json (Schema/SettingsSchema+Updates*.generated.swift,
// cx-d5b5d); this file only parses.

/// `updates.*` in cmux.json: one Automatic Updates choice (`updates.automatic`: off, notify, download,
/// idle) and the channel; the finer knobs stay in cmux.json, off the Settings page (cmuxterm-hq
/// docs/design/update-settings.md).
public nonisolated struct UpdatesSettings: Sendable, Equatable {
    /// The release ring this Mac follows in the cmux NEXT appcast (release rings).
    public var channel = UpdatesSettings.channelDefault
    /// How far cmux goes by itself: check, download, then install once idle. While the key is unset it
    /// reads the three toggles it replaced (retired-keys.json), then this build's default.
    public var automatic = UpdatesSettings.automaticDefault
    /// cmux checks by itself (every choice but Off).
    public var checkAutomatically: Bool { automatic != .off }
    /// Found updates download by themselves (Download Automatically and Install When Idle).
    public var downloadAutomatically: Bool { automatic == .download || automatic == .idle }
    /// A downloaded update installs by itself once the person is away (`installWhenIdleMinutes` with no
    /// input, or the screen locked), never over an unsent message (Install When Idle); a running agent turn
    /// does not hold it. NIGHTLY picks it by default (a build default).
    public var installWhenIdle: Bool { automatic == .idle }
    /// Seconds between automatic checks.
    public var checkIntervalSeconds = UpdatesSettings.checkIntervalDefault
    /// One click on a found update's Update downloads, installs and restarts (off: the Update Ready card asks first).
    public var oneClickInstall = UpdatesSettings.oneClickInstallDefault
    /// What's New's Versions list offers Install on each build (off until a nightly proves it).
    public var whatsNewInstall = UpdatesSettings.whatsNewInstallDefault
    public var installOnQuit = UpdatesSettings.installOnQuitDefault
    /// Minutes cmux must be idle before Install When Idle installs.
    public var installWhenIdleMinutes = UpdatesSettings.installWhenIdleMinutesDefault
    public var notify = UpdatesSettings.notifyDefault
    /// Previous builds kept for rollback (`cmux update rollback`).
    public var keepPreviousVersions = Int(UpdatesSettings.keepPreviousVersionsDefault)
    public var meteredNetwork = UpdatesSettings.meteredNetworkDefault
    /// Web UI updates between app updates (plans/cmux-next/web-ota.md); NIGHTLY builds only.
    public var web = UpdatesSettings.webDefault
    /// A web update's tree by `cas/1`, the whole archive on any miss (RFD 0166; off until a NIGHTLY proves it).
    public var webCas = UpdatesSettings.webCasDefault
    /// The web UI updates that apply: none under Automatic Updates Off (Off means cmux fetches nothing by
    /// itself), else `updates.web` (a hot swap needs no relaunch, so no idle gate).
    public var webInEffect: UpdatesWebSetting { automatic == .off ? .off : web }
    /// Pages and agent panes load from the server or overlay `~/.config/cmux-next/web-dev.json` names
    /// (the live web loop, docs/cmux-next/hot-reload.md); every build, on by default.
    public var liveWebReload = UpdatesSettings.liveWebReloadDefault
    /// The bottom-left "cmux Updated!" card after an update
    /// (WHATS-NEW-AFTER-UPDATE W1); managed config can force it off.
    public var showWhatsNew = UpdatesSettings.showWhatsNewDefault
    /// Seconds a nightly's idle install waits for agents, commands and input before it installs anyway.
    public var idleInstallMaxWaitSeconds = UpdatesSettings.idleInstallMaxWaitDefault
    /// Seconds keyboard and pointer input must be quiet before a nightly installs by itself.
    public var idleInstallQuietSeconds = UpdatesSettings.idleInstallQuietDefault

    public init() {}

    static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> Self {
        var settings = Self()
        guard var reader = ConfigFieldReader(root, at: ["updates"], diagnostics: &diagnostics) else { return settings }
        if let value = reader.choice("channel", UpdatesChannelSetting.self) { settings.channel = value }
        if let value = reader.choice("automatic", UpdatesAutomaticSetting.self) {
            settings.automatic = value
        } else if reader.members["automatic"] == nil,
                  let legacy = RenamedSettingKeys.legacyValue(for: automaticPath, in: root)?.stringValue.flatMap(UpdatesAutomaticSetting.init(rawValue:)) {
            // The toggles it replaced (updates.checkAutomatically, installWhenIdle, downloadAutomatically).
            settings.automatic = legacy
        }
        if let value = reader.number("checkIntervalSeconds", range: checkIntervalRange) { settings.checkIntervalSeconds = value }
        if let value = reader.bool("oneClickInstall") { settings.oneClickInstall = value }
        if let value = reader.bool("whatsNewInstall") { settings.whatsNewInstall = value }
        if let value = reader.bool("installOnQuit") { settings.installOnQuit = value }
        if let value = reader.number("installWhenIdleMinutes", range: installWhenIdleMinutesRange) {
            settings.installWhenIdleMinutes = value
        }
        if let legacy = root.value(at: notifyPath)?.stringValue.flatMap({ UpdatesNotifySetting.legacyValues[$0] }) {
            settings.notify = legacy
        } else if let value = reader.choice("notify", UpdatesNotifySetting.self) {
            settings.notify = value
        }
        if let value = reader.choice("meteredNetwork", UpdatesMeteredSetting.self) { settings.meteredNetwork = value }
        if let value = reader.choice("web", UpdatesWebSetting.self) { settings.web = value }
        if let value = reader.bool("webCas") { settings.webCas = value }
        if let value = reader.bool("liveWebReload") { settings.liveWebReload = value }
        if let value = reader.number("keepPreviousVersions", range: keepPreviousVersionsRange) { settings.keepPreviousVersions = Int(value) }
        if let value = reader.bool("showWhatsNew") { settings.showWhatsNew = value }
        if let value = reader.number("idleInstallMaxWaitSeconds", range: idleInstallMaxWaitRange) { settings.idleInstallMaxWaitSeconds = value }
        if let value = reader.number("idleInstallQuietSeconds", range: idleInstallQuietRange) { settings.idleInstallQuietSeconds = value }
        diagnostics = reader.diagnostics
        return settings
    }
}

