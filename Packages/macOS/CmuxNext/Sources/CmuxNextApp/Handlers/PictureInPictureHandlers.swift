import CmuxNextActions
import CmuxNextBrowser
import CmuxNextNowPlaying
import CmuxNextSettings
import CmuxNextSidebar

/// Picture in Picture for a browser tab's video, in either engine: the
/// tab's menu, the palette, a key bound to it, the media card's menu, the CLI
/// (`cmux media picture-in-picture`) and MCP run this one action, and the
/// card's button sends the same toggle to the tab it shows. The page's
/// video floats in the engine's own always-on-top window (Chromium's PiP
/// window, WebKit's), keeps playing while its tab is hidden or another
/// workspace shows (hibernation leaves a floating page alone, `PageProbe`),
/// and goes back into its tab when that window closes or the toggle runs again.
/// `media.pictureInPicture.enabled` off takes every one of these away (the action is
/// unavailable, the menus hide it, the card's and the media hub's buttons go); a site's own
/// video controls are the page's and stay.
@MainActor
enum PictureInPictureHandlers {
    static let actionID: ActionID = "tab.pictureInPicture"

    static func bind(into registry: ActionRegistry, context ctx: AppActionContext) {
        let cache = ctx.services.cache
        let services = ctx.services
        let enabled: @MainActor () -> Bool = { [weak services] in Self.isEnabled(services) }
        registry.bind(actionID, unavailable: { enabled() ? nil : PictureInPictureStrings.off }, invoke: { [weak registry] invocation in
            guard let registry, let page = page(ctx, invocation) else { return }
            let work = Task { @MainActor () -> String? in
                // Turned off between the run and this task: nothing floats.
                guard enabled() else { return PictureInPictureStrings.off }
                return switch await page.togglePictureInPicture() {
                case .noVideo?: PictureInPictureStrings.noVideo
                case .unsupported?: PictureInPictureStrings.unsupported
                case .entered?, .exited?, nil: nil
                }
            }
            // task-owner: a palette or menu run nobody waits on shows a refusal; a CLI or MCP run returns it.
            if registry.isCapturingWork {
                registry.track(Task { await work.value.map { ActionWorkFailure(refusal: .unavailable, reason: $0) } })
            } else {
                Task { [weak registry] in if let why = await work.value { registry?.refuse(why) } }
            }
        })
        // A tab's menu offers it on a page that plays (or played) a video; the media card's menu
        // (no target) while the card shows a tab's video.
        ActionTargetVisibility.hide(actionID, in: registry) { invocation in
            guard enabled() else { return true }
            guard let target = invocation.target else { return card(cache)?.canPictureInPicture != true }
            return target.kind == .tab && cache.existingBrowser(target.id)?.tab.state.media?.isVideo != true
        }
        // On a floating video the row reads as what it does.
        ActionTargetTitles.set(actionID, in: registry) { invocation in
            guard let target = invocation.target else {
                return card(cache)?.isPictureInPicture == true ? PictureInPictureStrings.exit : nil
            }
            guard target.kind == .tab,
                  cache.existingBrowser(target.id)?.tab.state.media?.isPictureInPicture == true else { return nil }
            return PictureInPictureStrings.exit
        }
    }

    /// `media.pictureInPicture.enabled`: cmux offers Picture in Picture (on when Settings are not loaded).
    static func isEnabled(_ services: AppServices?) -> Bool {
        services?.settings?.snapshot.nowPlaying.pictureInPicture ?? NowPlayingSettings.pictureInPictureDefault
    }

    /// The argument the media card's menu passes: the row acts on the tab the card shows.
    static let cardArgument = "nowPlayingCard"

    /// What the media card shows now.
    private static func card(_ cache: TabContentCache) -> SidebarNowPlaying? {
        let source: any NowPlayingSource = cache.pageRequests.nowPlayingCard.source ?? cache.pageRequests.sidebarSources
        return source.nowPlaying
    }

    /// The page it acts on: the named tab's; from the media card's menu, the
    /// tab the card shows; else the focused tab's when it shows a video; else
    /// the tab whose video plays (the one the media card shows, in any
    /// workspace); else the focused tab's, whose script may still find a
    /// video that never played.
    private static func page(_ ctx: AppActionContext, _ invocation: ActionInvocation) -> (any BrowserTab)? {
        let cache = ctx.services.cache
        if invocation.target?.kind == .tab || invocation["tab"]?.targetValue != nil {
            guard let (tab, _) = ctx.daemonTab(invocation) else { return nil }
            return cache.existingBrowser(tab.id)?.tab ?? ctx.refuse(PictureInPictureStrings.needsPage)
        }
        let shown = cache.pageRequests.sidebarNowPlaying.shownTab.flatMap { playing in
            cache.browsers.values.first(where: { $0.tab.id == playing })?.tab
        }.flatMap { $0.state.media?.isVideo == true ? $0 : nil }
        if invocation[cardArgument]?.boolValue == true { return shown ?? ctx.refuse(PictureInPictureStrings.noVideo) }
        let selected = ctx.services.windows.active?.focusedPane?.stripModel.selectedID
        let focused = selected.flatMap { cache.existingBrowser($0.rawValue)?.tab }
        if let focused, focused.state.media?.isVideo == true { return focused }
        return shown ?? focused ?? ctx.refuse(PictureInPictureStrings.noVideo)
    }
}

enum PictureInPictureStrings {
    static var exit: String {
        String(localized: "pictureInPicture.menu.exit", defaultValue: "Exit Picture in Picture", table: "Music", bundle: .module)
    }

    static var off: String {
        String(localized: "pictureInPicture.refusal.off",
               defaultValue: "Picture in Picture is turned off: turn on media.pictureInPicture.enabled in Settings › Browser › Media.",
               table: "Music", bundle: .module)
    }

    static var noVideo: String {
        String(localized: "pictureInPicture.refusal.noVideo", defaultValue: "No video to show in Picture in Picture.",
               table: "Music", bundle: .module)
    }

    static var unsupported: String {
        String(localized: "pictureInPicture.refusal.unsupported", defaultValue: "This video can’t play in Picture in Picture.",
               table: "Music", bundle: .module)
    }

    static var needsPage: String {
        String(localized: "pictureInPicture.refusal.needsPage", defaultValue: "Picture in Picture works on a web page’s video.",
               table: "Music", bundle: .module)
    }
}
