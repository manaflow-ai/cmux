import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextBridge
@testable import CmuxNextBrowser
@testable import CmuxNextNowPlaying
import Foundation
import Testing

/// Picture in Picture for a browser tab's video: the page's report says when its video floats, the
/// toggle runs in the page's world (the user gesture `requestPictureInPicture` needs) and says what
/// it did, the media card's source floats the tab it shows and names its site, a floating page is
/// never frozen or hibernated, and one action backs the tab menu, the card's menu, the palette,
/// the shortcut, the CLI and MCP.
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
        #expect(await PageProbe.run(tab).playingMedia == false, "an idle page counts as playing")
        tab.simulate(.mediaChanged(BrowserMediaState(title: "Clip", isPlaying: false, isVideo: true, isPictureInPicture: true)))
        let probe = await PageProbe.run(tab)
        #expect(probe.playingMedia, "a page whose video floats would freeze")
        #expect(probe.exemption(pressure: .critical) != nil, "a page whose video floats would hibernate")
    }

    @Test func oneActionBacksEveryEntrypoint() throws {
        let descriptor = try #require(ActionCatalog.all.first { $0.id == PictureInPictureHandlers.actionID }, "no Picture in Picture action")
        #expect(descriptor.defaultShortcut == Shortcut("p", modifiers: [.option, .shift, .command]))
        #expect(descriptor.cliName == "media picture-in-picture")
        #expect(descriptor.targets == [.tab])
        #expect(descriptor.surfacePlan.palette.isOffered && descriptor.surfacePlan.mcp?.isOffered == true)
        #expect(Set(descriptor.surfacePlan.contextMenus.map(\.context)) == [.tab, .nowPlayingCard])
    }
}
