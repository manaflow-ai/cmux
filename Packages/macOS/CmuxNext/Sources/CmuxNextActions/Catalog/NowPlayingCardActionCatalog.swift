// The sidebar's Now Playing card (u2437): put it away without a trip to Settings, bring it back,
// and play or pause what it shows. The card's x runs Hide; its right-click menu is generated from
// the `nowPlayingCard` placements below. Every action is also a palette row, a `cmux media` verb
// and an MCP tool. Picture in Picture floats a tab's video (the named tab, else the focused or
// playing one) and is also a tab menu row. Titles live in MusicActions.xcstrings.

nonisolated enum NowPlayingCardActionCatalog: ActionCatalogGroup {
    static func descriptors() -> [ActionDescriptor] {
        [
            ActionDescriptor(
                id: "nowPlaying.playPause", title: t("action.nowPlaying.playPause", "Play/Pause Media"),
                keywords: ["media", "music", "now playing", "play", "pause", "resume", "song"], category: .window,
                symbol: "playpause", surfaces: [.palette], cliName: "media play-pause",
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenus: [
                    ContextMenuPlacement(.nowPlayingCard, .navigate, 0, label: t("menu.nowPlaying.playPause", "Play/Pause")),
                ])
            ),
            ActionDescriptor(
                id: "tab.pictureInPicture", title: t("action.tab.pictureInPicture", "Picture in Picture"),
                keywords: ["pip", "picture in picture", "video", "float", "floating", "pop out", "always on top", "media", "tab"],
                category: .tab, symbol: "pip", surfaces: [.palette, .contextMenu], targets: [.tab], cliName: "media picture-in-picture",
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenus: [
                    ContextMenuPlacement(.tab, .identity, 211, folder: .options),
                    ContextMenuPlacement(.nowPlayingCard, .navigate, 10),
                ])
            ),
            ActionDescriptor(
                id: "nowPlaying.hideCard", title: t("action.nowPlaying.hideCard", "Hide Media Card"),
                keywords: ["media", "music", "now playing", "player", "card", "hide", "dismiss", "close", "sidebar"], category: .window,
                symbol: "xmark", surfaces: [.palette], cliName: "media hide-card",
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenus: [
                    ContextMenuPlacement(.nowPlayingCard, .close, 0, label: t("menu.nowPlaying.hide", "Hide")),
                ])
            ),
            ActionDescriptor(
                id: "nowPlaying.hideCardUntilRelaunch", title: t("action.nowPlaying.hideCardUntilRelaunch", "Hide Media Card Until Relaunch"),
                keywords: ["media", "music", "now playing", "player", "card", "hide", "dismiss", "relaunch", "sidebar"], category: .window,
                symbol: "eye.slash", surfaces: [.palette], cliName: "media hide-card-until-relaunch",
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenus: [
                    ContextMenuPlacement(.nowPlayingCard, .close, 10, label: t("menu.nowPlaying.hideUntilRelaunch", "Hide Until Relaunch")),
                ])
            ),
            ActionDescriptor(
                id: "nowPlaying.disableCard", title: t("action.nowPlaying.disableCard", "Never Show Media Card"),
                keywords: ["media", "music", "now playing", "player", "card", "hide", "never", "turn off", "disable", "sidebar"],
                category: .settings, symbol: "eye.slash.circle", surfaces: [.palette], cliName: "media disable-card",
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenus: [ContextMenuPlacement(.nowPlayingCard, .close, 100)])
            ),
            ActionDescriptor(
                id: "nowPlaying.showCard", title: t("action.nowPlaying.showCard", "Show Media Card"),
                keywords: ["media", "music", "now playing", "player", "card", "show", "turn on", "enable", "sidebar"],
                category: .settings, symbol: "music.note.list", surfaces: [.palette], cliName: "media show-card",
                // The band's right-click offers it while the card is put away, like Show Spaces.
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenus: [ContextMenuPlacement(.sidebarFooter, .view, 120)])
            ),
        ]
    }

    private static func t(_ key: StaticString, _ english: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: english, table: "MusicActions", bundle: .module)
    }
}
