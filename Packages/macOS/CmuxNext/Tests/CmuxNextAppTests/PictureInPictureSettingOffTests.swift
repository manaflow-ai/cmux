import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextBrowser
import CmuxNextDesign
@testable import CmuxNextNowPlaying
@testable import CmuxNextSettings
import CmuxNextSidebar
import Foundation
import Testing

/// `media.pictureInPicture.enabled` off: cmux offers no Picture in Picture of its own for a page's
/// video. The tab's menu, the media card's menu, the palette, a CLI or MCP run, the card's button
/// and the media hub's button all go; on (the default) every one is there, as before.
@MainActor @Suite(.serialized)
struct PictureInPictureSettingOffTests {
    @Test func offRemovesEveryPictureInPictureEntryPointAndOnBringsThemBack() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        let directory = FileManager.default.temporaryDirectory.appending(path: "cn-pip-setting-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "cmux.json")
        try Data("{}".utf8).write(to: url)
        let settings = SettingsController(registry: services.registry, design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        await settings.reload()
        #expect(settings.snapshot.nowPlaying.pictureInPicture, "on by default")
        services.settings = settings

        let tab = PictureInPictureTests.tab(), key = "video"
        services.cache.install(tab, for: key)
        defer { services.cache.browsers[key] = nil }
        tab.simulate(.mediaChanged(BrowserMediaState(title: "Clip", isPlaying: true, isVideo: true)))
        let id = PictureInPictureHandlers.actionID
        let cardSource = services.cache.pageRequests.sidebarNowPlaying

        func all(_ items: [NSMenuItem]) -> [NSMenuItem] { items.flatMap { [$0] + ($0.submenu.map { all($0.items) } ?? []) } }
        func tabRow() -> NSMenuItem? {
            let menu = services.registry.makeContextMenu(for: .tab, target: ActionTargetRef(kind: .tab, id: key), implied: .browserFocused)
            return all(menu.items).first { ActionRegistry.menuRun(of: $0)?.id == id }
        }
        func cardRow() -> NSMenuItem? {
            _ = services.cache.pageRequests.nowPlayingCard.card(for: cardSource.nowPlaying, from: cardSource)
            let menu = SidebarContextMenus.menu(for: .nowPlaying, model: SidebarModel(), services: services, scope: ThemeScope(level: .room))
            return all(menu?.items ?? []).first { ActionRegistry.menuRun(of: $0)?.id == id }
        }
        /// The media hub's Picture in Picture buttons in `menu` (a new menu by default).
        func hubButtons(_ menu: NSMenu? = nil) -> [NSButton] {
            let menu = menu ?? BrowserMediaMenu.menu(services, rows: BrowserMediaRows())
            func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
            return menu.items.compactMap(\.view).flatMap(views).compactMap { $0 as? NSButton }.filter {
                $0.accessibilityLabel() == BrowserMediaStrings.pictureInPicture || $0.accessibilityLabel() == BrowserMediaStrings.exitPictureInPicture
            }
        }
        /// The media hub's Picture in Picture button on the tab's card, when it shows.
        func hubButtonShows() -> Bool { hubButtons().contains { !$0.isHidden } }
        func describe() -> String {
            "tab row \(tabRow() != nil), card row \(cardRow() != nil), available \(services.registry.isAvailable(id)), "
                + "card button \(cardSource.nowPlaying?.canPictureInPicture == true), hub button \(hubButtonShows())"
        }

        // The default: every entry point offers it.
        #expect(tabRow() != nil, "\(describe())")
        #expect(cardRow() != nil, "\(describe())")
        #expect(services.registry.action(for: id)?.isEnabled() == true, "\(describe())")
        #expect(cardSource.nowPlaying?.canPictureInPicture == true, "\(describe())")
        #expect(hubButtonShows(), "\(describe())")
        // A hub left open while the setting turns off (its card was built with it on).
        let openHub = BrowserMediaMenu.menu(services, rows: BrowserMediaRows())
        let staleButton = try #require(hubButtons(openHub).first { !$0.isHidden })

        try await settings.set(.bool(false), at: NowPlayingSettings.pictureInPicturePath)
        try await PasswordManagerRouteTests.until({ services.settings?.snapshot.nowPlaying.pictureInPicture == false })
        #expect(tabRow() == nil, "the tab's menu still offers Picture in Picture: \(describe())")
        #expect(cardRow() == nil, "the media card's menu still offers Picture in Picture: \(describe())")
        #expect(services.registry.action(for: id)?.isEnabled() == false, "the palette still offers Picture in Picture: \(describe())")
        #expect(services.registry.unavailableReason(for: id) != nil, "a CLI or MCP run is not told why")
        tab.evaluationResult = .string("entered")
        #expect(!services.registry.perform(id, invocation: ActionInvocation(target: ActionTargetRef(kind: .tab, id: key))),
                "a run with the setting off still ran")
        #expect(cardSource.nowPlaying?.canPictureInPicture == false, "the card still shows its button: \(describe())")
        cardSource.perform(.pictureInPicture)
        #expect(!hubButtonShows(), "the media hub still shows its button: \(describe())")
        staleButton.performClick(nil)
        #expect(staleButton.isHidden, "the open hub's button still shows after a press with the setting off")
        #expect(staleButton.accessibilityLabel() == BrowserMediaStrings.pictureInPicture, "the open hub's button flipped to Exit")
        withExtendedLifetime(openHub) {}
        try await Task.sleep(for: .milliseconds(200))
        #expect(!tab.commands.contains(.evaluate(BrowserMediaCommand.pictureInPictureScript)), "the page's video floated with the setting off")

        try await settings.set(.bool(true), at: NowPlayingSettings.pictureInPicturePath)
        try await PasswordManagerRouteTests.until({ services.settings?.snapshot.nowPlaying.pictureInPicture == true })
        #expect(tabRow() != nil && cardRow() != nil && cardSource.nowPlaying?.canPictureInPicture == true && hubButtonShows(), "\(describe())")

        // Turned off between a run (or a hub press) and its task: nothing floats. The settings
        // change before either task runs, because nothing awaits in between.
        let offURL = directory.appending(path: "cmux-off.json")
        try Data(#"{"media": {"pictureInPicture": {"enabled": false}}}"#.utf8).write(to: offURL)
        let off = SettingsController(registry: services.registry, design: DesignSettings(), fileURL: offURL,
                                     managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        await off.reload()
        #expect(off.snapshot.nowPlaying.pictureInPicture == false)
        func floats() -> Int { tab.commands.filter { $0 == .evaluate(BrowserMediaCommand.pictureInPictureScript) }.count }
        // The media card's run (it acts on the tab the card shows) reaches the page while on.
        let cardRun = ActionInvocation(arguments: [PictureInPictureHandlers.cardArgument: .bool(true)])
        var before = floats()
        #expect(services.registry.perform(id, invocation: cardRun))
        try await Task.sleep(for: .milliseconds(200))
        #expect(floats() == before + 1, "the card's run never reached the page with the setting on")
        before = floats()
        // The hub stays open (its menu holds the card) while the setting turns off.
        let hub = BrowserMediaMenu.menu(services, rows: BrowserMediaRows())
        let hubButton = try #require(hubButtons(hub).first { !$0.isHidden })
        #expect(services.registry.perform(id, invocation: cardRun))
        hubButton.performClick(nil)
        #expect(hubButton.accessibilityLabel() == BrowserMediaStrings.exitPictureInPicture, "the hub's press shows Exit at once")
        services.settings = off
        try await Task.sleep(for: .milliseconds(200))
        #expect(floats() == before, "a run or press queued before the setting turned off still floated the video")
        #expect(hubButton.isHidden && hubButton.accessibilityLabel() == BrowserMediaStrings.pictureInPicture,
                "the hub's refused press still shows Exit")
        withExtendedLifetime(hub) {}
        services.settings = settings
    }
}
