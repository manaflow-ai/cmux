import CmuxNextActions
import CmuxNextBrowser
import CmuxNextNowPlaying
import CmuxNextSidebar

/// Picture in Picture for a browser tab's video, in either engine: the
/// tab's menu, the palette, ⌥⇧⌘P, the media card's menu, the CLI
/// (`cmux media picture-in-picture`) and MCP run this one action, and the
/// card's button sends the same toggle to the tab it shows. The page's
/// video floats in the engine's own always-on-top window (Chromium's PiP
/// window, WebKit's), keeps playing while its tab is hidden or another
/// workspace shows (hibernation leaves a floating page alone, `PageProbe`),
/// and goes back into its tab when that window closes or the toggle runs again.
@MainActor
enum PictureInPictureHandlers {
    static let actionID: ActionID = "tab.pictureInPicture"

    static func bind(into registry: ActionRegistry, context ctx: AppActionContext) {
        let cache = ctx.services.cache
        registry.bind(actionID, invoke: { invocation in
            guard let page = page(ctx, invocation) else { return }
            // task-owner: one page script; its answer only picks a refusal for the person.
            Task { @MainActor in
                switch await page.togglePictureInPicture() {
                case .noVideo?: ctx.refuse(PictureInPictureStrings.noVideo)
                case .unsupported?: ctx.refuse(PictureInPictureStrings.unsupported)
                case .entered?, .exited?, nil: break
                }
            }
        })
        // A tab's menu offers it on a page that plays (or played) a video; the media card's menu
        // (no target) while the card shows a tab's video.
        ActionTargetVisibility.hide(actionID, in: registry) { invocation in
            guard let target = invocation.target else {
                let card: any NowPlayingSource = cache.pageRequests.nowPlayingCard.source ?? cache.pageRequests.sidebarSources
                return card.nowPlaying?.canPictureInPicture != true
            }
            return target.kind == .tab && cache.existingBrowser(target.id)?.tab.state.media?.isVideo != true
        }
        // On a floating video the row reads as what it does.
        ActionTargetTitles.set(actionID, in: registry) { invocation in
            guard let target = invocation.target, target.kind == .tab,
                  cache.existingBrowser(target.id)?.tab.state.media?.isPictureInPicture == true else { return nil }
            return PictureInPictureStrings.exit
        }
    }

    /// The page it acts on: the named tab's; else the focused tab's when it
    /// shows a video; else the tab whose video plays (the one the media
    /// card shows, in any workspace); else the focused tab's, whose script
    /// may still find a video that never played.
    private static func page(_ ctx: AppActionContext, _ invocation: ActionInvocation) -> (any BrowserTab)? {
        let cache = ctx.services.cache
        if invocation.target?.kind == .tab || invocation["tab"]?.targetValue != nil {
            guard let (tab, _) = ctx.daemonTab(invocation) else { return nil }
            return cache.existingBrowser(tab.id)?.tab ?? ctx.refuse(PictureInPictureStrings.needsPage)
        }
        let selected = ctx.services.windows.active?.focusedPane?.stripModel.selectedID
        let focused = selected.flatMap { cache.existingBrowser($0.rawValue)?.tab }
        if let focused, focused.state.media?.isVideo == true { return focused }
        if let playing = cache.pageRequests.sidebarNowPlaying.shownTab,
           let page = cache.browsers.values.first(where: { $0.tab.id == playing })?.tab, page.state.media?.isVideo == true {
            return page
        }
        return focused ?? ctx.refuse(PictureInPictureStrings.noVideo)
    }
}

enum PictureInPictureStrings {
    static var exit: String {
        String(localized: "pictureInPicture.menu.exit", defaultValue: "Exit Picture in Picture", table: "Music", bundle: .module)
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
