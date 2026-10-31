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
        let model = ScreenshotsModel(watcher: NoWatch())
        let page = ScreenshotsPageTab(id: BrowserTabID(rawValue: "t1"), engine: .webkit, profile: .default, model: model,
                                      cache: ThumbnailCache(), workspace: RecordingWorkspace(), files: FileOperator())
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

/// A Screenshots page lists nothing until the person clicks Show Screenshots in it: not when an agent or a script
/// makes it, not when it is shown (an agent can show a tab: `cmux tab focus`, a browser mirror, the Home mirror),
/// and not when it is restored on screen at launch (after a privacy reset or on a new Mac, a read of ~/Desktop
/// then would raise the macOS folder prompt at launch: LAUNCH-NO-TCC-PROMPTS).
@MainActor @Suite(.serialized) struct ScreenshotsPageListsOnlyAfterTheClickTests {
    private static func page(_ key: String, services: AppServices) -> ScreenshotsPageTab {
        services.screenshotsPage.makePage(key: key, engine: .webkit, profile: .default)
    }

    private static func services() -> AppServices {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        return services
    }

    @Test func aRestoredOrAgentShownPageListsNothingUntilThePersonClicks() {
        let services = Self.services()
        let page = Self.page("restored-on-screen", services: services)
        defer { page.close() }
        // The app's page model never lists at once (the wiring: ScreenshotsPageService.makePage).
        #expect(!page.model.isListing)
        // Restored on screen at launch, or shown by an agent: the same call, and still nothing is read.
        page.setContentVisible(true)
        page.setFocused(true)
        // Plain values in each expectation: a failure message must not reflect the view (its drop pasteboard).
        let listedWhenShown = page.model.isListing, promptWhenShown = page.view.showsPrompt
        #expect(!listedWhenShown, "a shown page listed before the person clicked")
        #expect(promptWhenShown)
        // The person's click.
        page.view.showScreenshots()
        let listedAfterClick = page.model.isListing, promptAfterClick = page.view.showsPrompt
        #expect(listedAfterClick)
        #expect(!promptAfterClick)
    }

    @Test func screenshotsOpenFromAScriptWithFocusSaysItOpenedInTheBackground() async throws {
        let (services, controller, _) = try await CanvasLayoutActionTests.window()
        defer { controller.teardown(); controller.window?.close() }
        var run = ActionInvocation(origin: .cli)
        run.focusRequested = true
        run.viaControlSocket = true
        let captured = services.registry.capturingRun {
            _ = services.registry.perform("screenshots.open", invocation: run)
        }
        var fields: [String: ActionResultValue] = [:]
        for result in captured.results {
            if case .success(let value) = await result.value { fields.merge(value) { $1 } }
        }
        #expect(fields["opened"] == .string("background"), "a scripted open with focus said nothing: \(fields)")
        #expect(fields["note"] != nil)
    }
}
