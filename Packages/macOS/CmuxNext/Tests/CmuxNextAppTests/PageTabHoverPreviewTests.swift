import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextIcons
import CmuxNextTabs
import Foundation
import Testing

/// User, 2026-11-09: "hovering on markdown doesnt show me the preview". A Markdown tab's hover card
/// showed only its icon and title: the card's thumbnails came only from terminals and browser
/// pages. A page tab now shows a picture of its page, taken once on a hover and reused until the
/// page shows again.
@MainActor @Suite(.serialized) struct PageTabHoverPreviewTests {
    private final class Page: InternalPageProvider {
        let page: InternalPageID
        let title = "perf-status.md"
        let symbol = "doc.text"
        init(_ page: InternalPageID) { self.page = page }
        func makeView(for key: String, in window: WindowController?) -> NSView { NSView() }
    }

    /// Counts the pictures taken and answers each with `image`.
    private final class Camera {
        var taken = 0
        var image: CGImage?
        func capture() -> CGImage? {
            taken += 1
            return image
        }
    }

    private static let size = CGSize(width: 320, height: 200)

    @Test func aMarkdownTabsHoverCardShowsItsPagePicturedOnceUntilItShowsAgain() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        services.pages.register(Page(.markdown))
        let key = services.pages.open(.markdown, in: "pane-markdown-preview", of: DaemonStore())
        defer { services.pages.close(key) }
        let view = try #require(services.pages.view(for: key))
        let camera = Camera()
        camera.image = try NewTabHoverPreviewTests.striped()
        services.pages.pictures.capture = { _ in camera.capture() }
        // Another tab shows: the page is parked.
        view.isHidden = true

        #expect(await services.previews.previewImage(for: TabID(key), maxPixelSize: Self.size) != nil,
                "a Markdown tab's hover card had no picture of its page")
        #expect(await services.previews.previewImage(for: TabID(key), maxPixelSize: Self.size) != nil)
        #expect(camera.taken == 1, "a second hover pictured the parked page again")

        // It showed and was parked again: the next hover pictures it once more.
        view.isHidden = false
        view.isHidden = true
        #expect(await services.previews.previewImage(for: TabID(key), maxPixelSize: Self.size) != nil)
        #expect(camera.taken == 2, "a page that showed again kept its old picture")

        // Light to dark (or back): the page drew again in the other theme, so the next hover
        // pictures it once more. A capture of the light card showed the page's dark picture.
        let dark = view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        view.appearance = NSAppearance(named: dark ? .aqua : .darkAqua)
        #expect(await services.previews.previewImage(for: TabID(key), maxPixelSize: Self.size) != nil)
        #expect(camera.taken == 3, "a page kept its picture from the other theme")
    }

    @Test func aFlatPageCaptureIsNoPictureAndIsNotKept() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        services.pages.register(Page(.markdown))
        let key = services.pages.open(.markdown, in: "pane-markdown-flat", of: DaemonStore())
        defer { services.pages.close(key) }
        let view = try #require(services.pages.view(for: key))
        view.isHidden = true
        let camera = Camera()
        camera.image = try NewTabHoverPreviewTests.flat()
        services.pages.pictures.capture = { _ in camera.capture() }

        #expect(await services.previews.previewImage(for: TabID(key), maxPixelSize: Self.size) == nil,
                "a page that had not drawn was its card's picture")
        // The page drew: the next hover tries again and shows it.
        camera.image = try NewTabHoverPreviewTests.striped()
        #expect(await services.previews.previewImage(for: TabID(key), maxPixelSize: Self.size) != nil)
        #expect(camera.taken == 2)
    }

    /// A page whose theme changes before it hears of it (AppKit may tell a view late).
    private final class QuietPage: PagePictureSubject {
        let pictureKey = "local-page:markdown:quiet"
        let shownGeneration = 1
        let isOnScreen = true
        var pictureLook = "NSAppearanceNameAqua"
        func picture(maxPixelWidth: CGFloat) async -> CGImage? { nil }
    }

    /// The dark card of a capture showed the page's light picture: the kept picture stood for the page
    /// until the page counted a theme change, and a card can ask before the page has counted it.
    @Test func aPictureFromTheOtherThemeIsTakenAgainBeforeThePageHearsOfIt() async throws {
        _ = NSApplication.shared
        let pictures = PageTabPictures()
        let camera = Camera()
        camera.image = try NewTabHoverPreviewTests.striped()
        pictures.capture = { _ in camera.capture() }
        let page = QuietPage()
        #expect(await pictures.picture(of: page, maxPixelSize: Self.size) != nil)
        page.pictureLook = "NSAppearanceNameDarkAqua"
        #expect(await pictures.picture(of: page, maxPixelSize: Self.size) != nil)
        #expect(camera.taken == 2, "the card showed the page's picture from the other theme")
    }
}
