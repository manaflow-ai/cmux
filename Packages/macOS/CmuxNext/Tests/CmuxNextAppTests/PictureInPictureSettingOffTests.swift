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
        /// The media hub's Picture in Picture button on the tab's card, when it shows.
        func hubButtonShows() -> Bool {
            let menu = BrowserMediaMenu.menu(services, rows: BrowserMediaRows())
            func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
            let buttons = menu.items.compactMap(\.view).flatMap(views).filter {
                $0.accessibilityLabel() == BrowserMediaStrings.pictureInPicture || $0.accessibilityLabel() == BrowserMediaStrings.exitPictureInPicture
            }
            return buttons.contains { !$0.isHidden }
        }
        func describe() -> String {
            "tab row \(tabRow() != nil), card row \(cardRow() != nil), available \(services.registry.isAvailable(id)), "
                + "card button \(cardSource.nowPlaying?.canPictureInPicture == true), hub button \(hubButtonShows())"
        }

        // The default: every entry point offers it.
        #expect(tabRow() != nil, describe())
        #expect(cardRow() != nil, describe())
        #expect(services.registry.action(for: id)?.isEnabled() == true, describe())
        #expect(cardSource.nowPlaying?.canPictureInPicture == true, describe())
        #expect(hubButtonShows(), describe())

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
        try await Task.sleep(for: .milliseconds(200))
        #expect(!tab.commands.contains(.evaluate(BrowserMediaCommand.pictureInPictureScript)), "the page's video floated with the setting off")

        try await settings.set(.bool(true), at: NowPlayingSettings.pictureInPicturePath)
        try await PasswordManagerRouteTests.until({ services.settings?.snapshot.nowPlaying.pictureInPicture == true })
        #expect(tabRow() != nil && cardRow() != nil && cardSource.nowPlaying?.canPictureInPicture == true && hubButtonShows(), describe())
    }
}
