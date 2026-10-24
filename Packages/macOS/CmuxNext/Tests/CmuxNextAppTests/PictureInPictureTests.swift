import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextHibernation
import CmuxNextBridge
@testable import CmuxNextBrowser
import CmuxNextDesign
@testable import CmuxNextNowPlaying
import CmuxNextSidebar
import Foundation
import Testing

/// Picture in Picture for a browser tab's video: the page's report says when its video floats, the
/// toggle runs in the page's world (the user gesture `requestPictureInPicture` needs) and says what
/// it did, the media card's source floats the tab it shows and names its site, a floating page is
/// never frozen or hibernated, and one action backs the tab menu, the card's menu, the palette,
/// a key bound to it, the CLI and MCP.
@MainActor struct PictureInPictureTests {
    static func tab() -> MockBrowserTab {
        MockBrowserEngine(kind: .cef).makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://www.youtube.com/watch?v=1")))
    }

    @Test func aReportSaysWhetherItsVideoFloats() throws {
        let floating = try #require(BrowserMediaState.report(["title": "Clip", "playing": true, "video": true, "pip": true]) ?? nil)
        #expect(floating.isPictureInPicture && floating.isVideo)
        let inline = try #require(BrowserMediaState.report(["title": "Clip", "playing": true, "video": true]) ?? nil)
        #expect(!inline.isPictureInPicture, "a report without pip floats")
    }

    @Test func theToggleRunsInThePagesWorldAndSaysWhatItDid() async {
        #expect(BrowserMediaCommand.pictureInPicture.script.world == .page, "requestPictureInPicture needs the page world's user gesture")
        let tab = Self.tab()
        tab.evaluationResult = .string("noVideo")
        #expect(await tab.togglePictureInPicture() == .noVideo)
        #expect(tab.commands.contains(.evaluate(BrowserMediaCommand.pictureInPictureScript)), "the toggle did not run the page script")
        tab.evaluationResult = .string("entered")
        #expect(await tab.togglePictureInPicture() == .entered)
        tab.evaluationResult = .null
        #expect(await tab.togglePictureInPicture() == nil, "a page that did not answer reads as an answer")
    }

    @Test func theCardsSourceFloatsTheVideoOfTheTabItShows() async throws {
        let tab = Self.tab()
        let media = BrowserMediaState(title: "Clip", isPlaying: true, isVideo: true, isPictureInPicture: true)
        let source = BrowserTabsNowPlaying()
        source.follow(sessions: { [NowPlayingSession(tab: tab.id, media: media)] }, tab: { _ in tab })
        let shown = try #require(source.nowPlaying, "the source shows no tab")
        #expect(shown.canPictureInPicture && shown.isPictureInPicture)
        #expect(!shown.labels.pictureInPicture.isEmpty && !shown.labels.exitPictureInPicture.isEmpty)
        #expect(source.shownTab == tab.id)
        source.perform(.pictureInPicture)
        try await PasswordManagerRouteTests.until({ tab.commands.contains(.evaluate(BrowserMediaCommand.pictureInPictureScript)) },
                                                  within: .seconds(5)) { "the card's Picture in Picture never reached the tab" }
    }

    @Test func theSiteIsTheHostWithoutWWW() {
        #expect(BrowserTabsNowPlaying.site(URL(string: "https://www.youtube.com/watch?v=1")) == "youtube.com")
        #expect(BrowserTabsNowPlaying.site(URL(string: "https://music.example.org/")) == "music.example.org")
        #expect(BrowserTabsNowPlaying.site(nil) == "")
    }

    /// A paused or muted video in its floating window still plays for the person: the page stays awake.
    @Test func aFloatingPageIsNeverFrozen() async {
        let tab = Self.tab()
        tab.evaluationResult = .string(#"{"media":false,"form":false,"audio":false,"capturing":false}"#)
        #expect(await BrowserHibernation.probe(tab).playingMedia == false, "an idle page counts as playing")
        tab.simulate(.mediaChanged(BrowserMediaState(title: "Clip", isPlaying: false, isVideo: true, isPictureInPicture: true)))
        let probe = await BrowserHibernation.probe(tab)
        #expect(probe.playingMedia, "a page whose video floats would freeze")
        #expect(probe.exemption != nil, "a page whose video floats would hibernate")
    }

    @Test func aTabsMenuOffersItOnAVideoAndReadsAsExitWhileItFloats() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        let tab = Self.tab(), key = "video"
        services.cache.install(tab, for: key)
        defer { services.cache.browsers[key] = nil }
        func row() -> NSMenuItem? {
            func all(_ items: [NSMenuItem]) -> [NSMenuItem] { items.flatMap { [$0] + ($0.submenu.map { all($0.items) } ?? []) } }
            let menu = services.registry.makeContextMenu(for: .tab, target: ActionTargetRef(kind: .tab, id: key), implied: .browserFocused)
            return all(menu.items).first { ActionRegistry.menuRun(of: $0)?.id == PictureInPictureHandlers.actionID }
        }
        #expect(row() == nil, "a page with no video offers Picture in Picture")
        tab.simulate(.mediaChanged(BrowserMediaState(title: "Clip", isPlaying: true, isVideo: true)))
        #expect(try #require(row(), "a page playing a video leaves Picture in Picture out").title == "Picture in Picture")
        tab.simulate(.mediaChanged(BrowserMediaState(title: "Clip", isPlaying: true, isVideo: true, isPictureInPicture: true)))
        #expect(row()?.title == PictureInPictureStrings.exit, "the row of a floating video does not read as Exit")
    }

    /// The card's menu floats the tab the card shows (no tab has focus here), offers it only for a
    /// video and reads as Exit while it floats.
    @Test func theCardsMenuFloatsTheTabTheCardShows() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        let tab = Self.tab(), key = "video"
        services.cache.install(tab, for: key)
        defer { services.cache.browsers[key] = nil }
        let tabs = services.cache.pageRequests.sidebarNowPlaying
        func row() -> NSMenuItem? {
            // The card shows the browser tabs' media, as the sidebar's feed offers it.
            _ = services.cache.pageRequests.nowPlayingCard.card(for: tabs.nowPlaying, from: tabs)
            func all(_ items: [NSMenuItem]) -> [NSMenuItem] { items.flatMap { [$0] + ($0.submenu.map { all($0.items) } ?? []) } }
            let menu = SidebarContextMenus.menu(for: .nowPlaying, model: SidebarModel(), services: services, scope: ThemeScope(level: .room))
            return all(menu?.items ?? []).first { ActionRegistry.menuRun(of: $0)?.id == PictureInPictureHandlers.actionID }
        }
        tab.simulate(.mediaChanged(BrowserMediaState(title: "Song", isPlaying: true)))
        #expect(row() == nil, "the card of a song offers Picture in Picture")
        tab.simulate(.mediaChanged(BrowserMediaState(title: "Clip", isPlaying: true, isVideo: true)))
        let item = try #require(row(), "the card of a video leaves Picture in Picture out")
        #expect(item.title == "Picture in Picture")
        tab.evaluationResult = .string("entered")
        let run = try #require(ActionRegistry.menuRun(of: item))
        #expect(services.registry.perform(run.id, invocation: ActionInvocation(target: run.target, arguments: run.arguments)))
        try await PasswordManagerRouteTests.until({ tab.commands.contains(.evaluate(BrowserMediaCommand.pictureInPictureScript)) },
                                                  within: .seconds(5)) { "the card's row never reached the tab the card shows" }
        tab.simulate(.mediaChanged(BrowserMediaState(title: "Clip", isPlaying: true, isVideo: true, isPictureInPicture: true)))
        #expect(row()?.title == PictureInPictureStrings.exit, "the card's row of a floating video does not read as Exit")
    }

    @Test func oneActionBacksEveryEntrypoint() throws {
        let descriptor = try #require(ActionCatalog.all.first { $0.id == PictureInPictureHandlers.actionID }, "no Picture in Picture action")
        #expect(descriptor.cliName == "media picture-in-picture")
        #expect(descriptor.targets == [.tab])
        #expect(descriptor.surfacePlan.palette.isOffered && descriptor.surfacePlan.mcp?.isOffered == true)
        #expect(Set(descriptor.surfacePlan.contextMenus.map(\.context)) == [.tab, .nowPlayingCard])
    }
}
