import AppKit
import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextSettings
import CmuxNextSidebar
import CmuxNextWakeups
import Foundation
import os

/// The New Tab page's Now Playing player: what plays on the card's sources, pushed to every agent
/// page (`AgentPaneNowPlaying`) as the follow sees it change (`followNowPlaying`), nil while the New
/// Tab player is off (`tabs.newTabNowPlaying`, apart from the sidebar card's own setting) or nothing
/// plays; the page's controls run on the card's sources, and its menu's page items through ``page``. The artwork is
/// redrawn as a small PNG data URL once per image: cmux's own player hands over the file's embedded
/// art as is, and every track change goes to every agent page.
@MainActor
enum NewTabNowPlaying {
    /// The last artwork encoded, and its data URL (nil when the bytes are not an image).
    private static var artwork: (data: Data, url: String?)?
    /// The artwork's side in pixels: the page's 72pt slot at 2x, with room to spare.
    static let artworkSide = 176

    /// What the page's menu asks of the App beyond the transport: Hide Now Playing and its Undo
    /// write `tabs.newTabNowPlaying`, Now Playing Settings… opens Settings at that row, and Open in
    /// brings the app that plays forward.
    struct Page {
        var setShown: (Bool) -> Void = { _ in }
        var openSettings: () -> Void = {}
        var openApp: (String) -> Void = { _ in }
    }

    /// The App's actions for the page's menu (`followNowPlaying(_:settings:registry:)` sets them, `liveActions`).
    static var page = Page()

    /// Pushes `shown` to `player`'s pages (every agent page's, but a test's own player in tests).
    static func show(_ shown: SidebarNowPlaying?, from source: any NowPlayingSource, to player: AgentPaneNowPlaying = .shared) {
        player.onCommand = { [weak source] command in
            guard let source else { return }
            perform(command, on: source)
        }
        if let data = shown?.artwork, artwork?.data != data {
            artwork = (data, artworkURL(data))
        }
        player.track = shown.map { track($0, artwork: $0.artwork == nil ? nil : artwork?.url ?? nil) }
    }

    /// Runs a page's control: the transport on `source`, the menu's page items through ``page``.
    static func perform(_ command: AgentPaneNowPlaying.Command, on source: any NowPlayingSource) {
        switch command {
        case .open: if let app = source.nowPlaying?.app { page.openApp(app.bundleIdentifier) }
        case .show(let shown): page.setShown(shown)
        case .settings: page.openSettings()
        case .playPause, .previous, .next, .seek: if let control = sidebarCommand(command) { source.perform(control) }
        }
    }

    /// The image redrawn as an `artworkSide` PNG data URL, or nil when the bytes are not an image.
    static func artworkURL(_ data: Data) -> String? {
        SystemNowPlaying.png(data, side: artworkSide).map { "data:image/png;base64," + $0.base64EncodedString() }
    }

    /// The card's track as the page draws it.
    static func track(_ shown: SidebarNowPlaying, artwork: String?) -> AgentPaneNowPlaying.Track {
        let labels = shown.labels
        return AgentPaneNowPlaying.Track(
            title: shown.title, artist: shown.artist, artwork: artwork, isPlaying: shown.isPlaying, position: shown.position,
            duration: shown.duration, rate: shown.rate, positionDate: shown.positionDate, canPrevious: shown.canPrevious,
            canNext: shown.canNext,
            labels: ["play": labels.play, "pause": labels.pause, "previous": labels.previous, "next": labels.next],
            source: shown.app?.name)
    }

    /// The transport control a page's command is, nil for the menu's page items.
    static func sidebarCommand(_ command: AgentPaneNowPlaying.Command) -> SidebarNowPlayingCommand? {
        switch command {
        case .playPause: .playPause
        case .previous: .previous
        case .next: .next
        case .seek(let seconds): .seek(seconds)
        case .open, .show, .settings: nil
        }
    }

    /// The App's page actions: the setting written as the page (`tabs.newTabNowPlaying` is agent
    /// settable; Undo removes the key, back to the default), Settings… through `openSettings`
    /// with the row's key, and the app opened off the main thread (a Launch Services call).
    static func liveActions(settings: @escaping @MainActor () -> SettingsController?, registry: ActionRegistry?,
                            queries: WorkspaceQueries?) -> Page {
        Page(
            setShown: { shown in
                guard let settings = settings() else { return }
                // main-hop-allow: the write is SettingsController's own main-actor async write (its file write runs off main); the task only starts it and logs a refusal
                Task {
                    do {
                        try await settings.setSetting(at: NowPlayingSettings.newTabPath, to: shown ? nil : .bool(false), by: .caller("page"))
                    } catch {
                        Logger(subsystem: "com.cmuxterm.app.next", category: "nowplaying")
                            .error("new tab now playing write failed: \(String(describing: error), privacy: .public)")
                    }
                }
            },
            openSettings: { [weak registry] in
                let key = NowPlayingSettings.newTabPath.joined(separator: ".")
                _ = registry?.perform("openSettings", invocation: ActionInvocation(arguments: ["section": .string("general"), "setting": .string(key)]))
            },
            openApp: { bundleIdentifier in
                // Launch Services finds the app on the system lane; the launch itself is asynchronous.
                queries?.value(WorkspaceQuery<URL?>.application(withBundleIdentifier: bundleIdentifier), priority: .userBlocking) { url in
                    guard let url else { return }
                    NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
                }
            })
    }
}
