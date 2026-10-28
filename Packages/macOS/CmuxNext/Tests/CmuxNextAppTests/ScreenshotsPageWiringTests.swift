import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextBrowser
import CmuxNextFileGrid
import CmuxNextFiles
import CmuxNextIcons
import CmuxNextScreenshots
import Foundation
import Testing
import CmuxNextWakeups

/// The Screenshots pane in the app: one registered action opens it from the palette, the Window
/// menu and the CLI; `cmux://screenshots` routes to the native page with its icon; the page tab
/// filters on Find and leaves for a web address.
@MainActor @Suite struct ScreenshotsPageWiringTests {
    @Test func oneActionOffersThePaneOnThePaletteTheMenuAndTheCLI() throws {
        let matches = ActionCatalog.all.filter { $0.id == "screenshots.open" }
        #expect(matches.count == 1)
        let action = try #require(matches.first)
        #expect(action.surfaces.contains(.palette))
        #expect(action.surfaces.contains(.menu))
        #expect(action.cliName == "screenshots open")
        #expect(action.mainMenu == .window)
        #expect(action.keywords.contains("screenshots"))
    }

    @Test func theAddressIsANativePageWithTheImagesIcon() {
        #expect(TabContentCache.isAppPage(ScreenshotsPageAddress.url))
        #expect(TabContentCache.isAppPage(URL(string: "cmux://screenshots/")))
        #expect(!TabContentCache.isAppPage(URL(string: "https://screenshots.example")))
        #expect(BrowserTabIconState.pageIcon(ScreenshotsPageAddress.url) == .sitePermissionImages)
    }

    @Test func thePageFiltersOnFindAndLeavesForAWebAddress() async throws {
        let work = linklessMainWork()
        let model = ScreenshotsModel(watcher: NoWatch(), mainWork: work)
        let page = ScreenshotsPageTab(id: BrowserTabID(rawValue: "t1"), engine: .webkit, profile: .default, model: model,
                                      cache: ThumbnailCache(), workspace: RecordingWorkspace(), files: FileOperator(work: BackgroundWork()), mainWork: work)
        defer { page.close() }
        #expect(page.state.url == ScreenshotsPageAddress.url)
        #expect(page.state.title == ScreenshotsPageAddress.title)
        _ = await page.find("shot", direction: .forward, caseSensitive: false)
        #expect(model.query == "shot")
        page.clearFind()
        #expect(model.query.isEmpty)
        var left: URL?
        page.onNavigate = { left = $0 }
        page.load(ScreenshotsPageAddress.url)
        #expect(left == nil)
        let web = try #require(URL(string: "https://cmux.com"))
        page.load(web)
        #expect(left == web)
    }
}

/// No file system events: the page test sets no folders.
private nonisolated struct NoWatch: FolderWatching {
    func changes(in folder: URL) -> AsyncStream<FolderChange> { AsyncStream { $0.finish() } }
}

/// Records what the grid asks of the system.
@MainActor private final class RecordingWorkspace: ScreenshotsWorkspace {
    var opened: [URL] = []
    func open(_ urls: [URL]) { opened += urls }
    func reveal(_ urls: [URL]) {}
}
