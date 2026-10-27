import AppKit
import CmuxNextActions
import CmuxNextDesign
import CmuxNextNowPlaying
import CmuxNextSettings

/// The Now Playing card's actions (u2437), one path for the card's x, its right-click menu, the
/// band's Show Media Card, the palette, the CLI (`cmux media …`) and MCP: Hide puts the card away
/// until other media starts, Hide Until Relaunch for this run, Never Show Media Card turns
/// `sidebar.nowPlaying.enabled` off (a toast says how to turn it on again, with Undo), Show Media
/// Card ends every hide and turns the setting on, Play/Pause runs on what the card shows.
enum NowPlayingCardHandlers {
    static let settingPath = "sidebar.nowPlaying.enabled"

    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let services = context.services
        let dismissal = services.cache.pageRequests.nowPlayingCard
        registry.bind("nowPlaying.hideCard", invoke: { [weak registry] _ in
            if !dismissal.hideShown() { registry?.refuse(NowPlayingCardStrings.noCard, quiet: true) }
        })
        registry.bind("nowPlaying.hideCardUntilRelaunch", invoke: { _ in dismissal.hideUntilRelaunch() })
        registry.bind("nowPlaying.disableCard", invoke: { [weak registry, weak services] invocation in
            guard let registry else { return }
            setEnabled(false, registry: registry, origin: invocation.origin)
            if let services { toastDisabled(services, registry: registry) }
        })
        registry.bind("nowPlaying.showCard", invoke: { [weak registry] invocation in
            dismissal.reset()
            if let registry { setEnabled(true, registry: registry, origin: invocation.origin) }
        })
        // The band offers Show Media Card only while the card is put away.
        ActionTargetVisibility.hide("nowPlaying.showCard", in: registry) { [weak services] _ in
            let enabled = services?.settings?.snapshot.nowPlaying.enabled ?? NowPlayingSettings.enabledDefault
            return enabled && dismissal.hiddenMedia == nil && !dismissal.hiddenUntilRelaunch
        }
        // What the card shows (its follow's source), else the sidebar's sources.
        registry.bind("nowPlaying.playPause", invoke: { [weak services, weak registry] _ in
            let source: (any NowPlayingSource)? = dismissal.source ?? services?.nowPlayingSources
            guard let source, source.nowPlaying != nil else {
                registry?.refuse(NowPlayingCardStrings.nothingPlaying)
                return
            }
            source.perform(.playPause)
        })
    }

    /// `sidebar.nowPlaying.enabled` through the one setting path (`palette.toggleSetting`).
    private static func setEnabled(_ on: Bool, registry: ActionRegistry, origin: ActionOrigin) {
        _ = registry.perform("palette.toggleSetting", invocation: ActionInvocation(
            arguments: ["setting": .string(settingPath), "on": .bool(on)], origin: origin))
    }

    /// Says where the card comes back from, with Undo, on the active window.
    private static func toastDisabled(_ services: AppServices, registry: ActionRegistry) {
        guard let window = services.windows.active?.window ?? NSApp.mainWindow else { return }
        let toast = CmuxToast(id: "now-playing-card-off", message: NowPlayingCardStrings.disabledToast,
                              action: .undo(), duration: .seconds(8))
        let handle = CmuxToastCenter.shared.show(toast, in: window)
        handle.onAction = { [weak registry] in _ = registry?.perform("nowPlaying.showCard", invocation: ActionInvocation(origin: .user)) }
    }
}

enum NowPlayingCardStrings {
    static var disabledToast: String {
        String(localized: "nowPlaying.toast.disabled",
               defaultValue: "Media card turned off. Turn it on again in Settings › Appearance › Show Now Playing, or run “Show Media Card” from the command palette.",
               table: "Music", bundle: .module)
    }

    static var noCard: String {
        String(localized: "nowPlaying.refusal.noCard", defaultValue: "No media card is showing.", table: "Music", bundle: .module)
    }

    static var nothingPlaying: String {
        String(localized: "nowPlaying.refusal.nothingPlaying", defaultValue: "Nothing is playing.", table: "Music", bundle: .module)
    }
}
