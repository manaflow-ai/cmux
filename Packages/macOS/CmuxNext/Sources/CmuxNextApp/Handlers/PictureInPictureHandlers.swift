import CmuxNextActions
import CmuxNextBrowser
import CmuxNextNowPlaying
import CmuxNextSettings
import CmuxNextSidebar
import CmuxNextWindowRules

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
        // A tab's menu offers it on a page with a video, the card's while it shows one; a floating one reads Exit (`browser::pip_row`).
        let row: @MainActor (ActionInvocation) -> WindowRules.PipRow? = { invocation in
            let (target, shown) = (invocation.target, invocation.target == nil ? card(cache) : nil)
            let media = target.flatMap { $0.kind == .tab ? cache.existingBrowser($0.id)?.tab.state.media : nil }
            return WindowRules().pipRow(.init(enabled: enabled(), target: target.map { $0.kind == .tab ? "tab" : "other" } ?? "card",
                                              video: media?.isVideo ?? shown?.canPictureInPicture ?? false,
                                              floating: media?.isPictureInPicture ?? shown?.isPictureInPicture ?? false))
        }
        ActionTargetVisibility.hide(actionID, in: registry) { row($0)?.hidden ?? true }
        ActionTargetTitles.set(actionID, in: registry) { row($0)?.exit == true ? PictureInPictureStrings.exit : nil }
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
        let cache = ctx.services.cache, naming = invocation.target?.kind == .tab || invocation["tab"]?.targetValue != nil
        var named: (any BrowserTab)?
        if naming {
            guard let (tab, _) = ctx.daemonTab(invocation) else { return nil }
            named = cache.existingBrowser(tab.id)?.tab
        }
        // The card's tab by its page's tab id (a moved or adopted page keeps another key); runs only on this action.
        let shown = cache.pageRequests.sidebarNowPlaying.shownTab.flatMap { playing in
            cache.browsers.values.first(where: { $0.tab.id == playing })?.tab
        }.flatMap { $0.state.media?.isVideo == true ? $0 : nil }
        let focused = ctx.services.windows.active?.focusedPane?.stripModel.selectedID.flatMap { cache.existingBrowser($0.rawValue)?.tab }
        let facts = WindowRules.PipFacts(named: naming, namedPage: named != nil, card: invocation[cardArgument]?.boolValue == true,
                                         shownVideo: shown != nil, focused: focused != nil, focusedVideo: focused?.state.media?.isVideo == true)
        switch WindowRules().pipPage(facts) { // cmux-window-rules `browser::pip_page`
        case .named?: return named
        case .shown?: return shown
        case .focused?: return focused
        case .needsPage?: return ctx.refuse(PictureInPictureStrings.needsPage)
        case .noVideo?, nil: return ctx.refuse(PictureInPictureStrings.noVideo)
        }
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
