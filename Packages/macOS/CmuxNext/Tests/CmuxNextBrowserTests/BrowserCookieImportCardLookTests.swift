import AppKit
@testable import CmuxNextBrowser
@testable import CmuxNextDesign
import Testing

/// Lawrence, 2026-10-31, on NIGHTLY: "border here looks bad" (the Import Cookies banner over a
/// page). The banner drew the theme-tinted overlay glass with a square gray veil clipped inside
/// it, so its edge read as a dark, heavy outline whose corners did not follow the glass, and it
/// cast no shadow. It keeps the dialog radius and the popups' shadow, with no veil of its own.
///
/// Leo, 2026-11-06, on NIGHTLY: "The bottom import is unthemed." The neutral gray glass and the
/// browser's plain gray text buttons ignored the app theme, where the browser's other prompts (the
/// prompt bar, notices, the cookie consent panel) draw the theme's glass tint. The banner takes the
/// theme's glass and the app's standard dialog buttons: Import in the theme's accent, Not Now in its gray.
///
/// Leo, 2026-11-07: "This thing, um, this looks kind of ugly, to be honest. Like this isn't styled
/// well." Its lines and answers are a React page on the design scale (webviews/src/pages/cookie-import;
/// the row's look is CookieImportCard.test.tsx's); this view hosts it: the glass, the shadow, the
/// size the page reports, and the page's answers back to the chrome.
@MainActor @Suite(.serialized) struct BrowserCookieImportCardLookTests {
    /// The card's page, as the host sees it: the states pushed and a hook to send messages back.
    @MainActor final class FakePage: BrowserChromeWebContent {
        let view: NSView = NSView()
        var onMessage: ((String, [String: Any]) -> Void)?
        var pushed: [[String: Any]] = []
        var closed = false
        func push(_ state: [String: Any]) { pushed.append(state) }
        func focus() {}
        func close() { closed = true }
        func send(_ kind: String, _ params: [String: Any]) { onMessage?(kind, params) }
    }

    static let offer = BrowserCookieImportOffer(icons: [], title: "Import cookies from Google Chrome",
                                                detail: "Stay signed in to your sites. Nothing leaves this Mac.",
                                                importTitle: "Import…", notNowTitle: "Not Now", neverTitle: "Don't Show Again")

    static func card(_ page: FakePage = FakePage(), offer: BrowserCookieImportOffer = offer) -> BrowserCookieImportCard {
        let card = BrowserCookieImportCard(offer: offer) { page }
        card.frame = NSRect(x: 0, y: 0, width: 460, height: 110)
        card.layoutSubtreeIfNeeded()
        return card
    }

    @Test func theCardSendsItsPageTheOffersLinesInOnePush() throws {
        let page = FakePage()
        let card = Self.card(page)
        let state = try #require(page.pushed.last)
        #expect(page.pushed.count == 1)
        #expect(state["title"] as? String == "Import cookies from Google Chrome")
        #expect(state["detail"] as? String == "Stay signed in to your sites. Nothing leaves this Mac.")
        #expect(state["importTitle"] as? String == "Import…")
        #expect(state["notNowTitle"] as? String == "Not Now")
        #expect(state["neverTitle"] as? String == "Don't Show Again")
        #expect(state["icon"] == nil, "an offer with no icon sends none")
        #expect(card.content != nil)
    }

    @Test func theBrowsersIconGoesToThePageAsAnInlinePNG() throws {
        let icon = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            NSColor.systemBlue.setFill()
            rect.fill()
            return true
        }
        var offer = Self.offer
        offer.icons = [icon]
        let page = FakePage()
        _ = Self.card(page, offer: offer)
        let url = try #require(page.pushed.last?["icon"] as? String)
        #expect(url.hasPrefix("data:image/png;base64,"))
        #expect(BrowserCookieImportCard.iconDataURL(NSImage(), pixels: 64) == nil, "an empty image is no icon")
    }

    @Test func eachAnswerOnThePageReachesTheChrome() {
        let page = FakePage()
        let card = Self.card(page)
        var answers: [BrowserCookieImportChoice] = []
        card.onChoice = { answers.append($0) }
        for wire in ["never", "notNow", "import", "bogus"] { page.send("command", ["type": wire, "revision": 1]) }
        #expect(answers == [.never, .notNow, .importCookies])
        card.isDismissing = true
        page.send("command", ["type": "import", "revision": 1])
        #expect(answers.count == 3, "a closing card answers nothing more")
    }

    @Test func theCardShowsAtTheHeightThePageMeasuredAndFollowsItsChanges() throws {
        let page = FakePage()
        let card = Self.card(page)
        var ready = 0
        var resized = 0
        card.onReady = { ready += 1 }
        card.onResize = { resized += 1 }
        page.send("size", ["height": 77.2, "revision": 0])
        #expect(!card.isMeasured, "a report of another state is dropped")
        page.send("size", ["height": 77.2, "revision": 1])
        #expect(card.isMeasured && ready == 1 && resized == 0)
        card.layoutSubtreeIfNeeded()
        #expect(card.frame.height == 78)
        page.send("size", ["height": 78, "revision": 1])
        #expect(resized == 0, "the same height places nothing again")
        page.send("size", ["height": 96, "revision": 1])
        #expect(ready == 1 && resized == 1)
    }

    @Test func aRetiredCardClosesItsPage() {
        let page = FakePage()
        let card = Self.card(page)
        card.retire()
        #expect(page.closed)
        #expect(card.content == nil)
    }

    @Test func theBannerIsTheThemesGlassInTheDialogRadius() throws {
        let glass = try #require(Self.card().glass)
        #expect(glass.tone == .theme)
        #expect(glass.rimView == nil)
        #expect(glass.cornerRadius == FloatingGlassStyle.dialog.cornerRadius)
    }

    @Test func theBannerHasNoVeilOfItsOwnUnderItsText() throws {
        let glass = try #require(Self.card().glass)
        func veils(_ view: NSView) -> Int {
            (view is OverlayBackingView ? 1 : 0) + view.subviews.map(veils).reduce(0, +)
        }
        #expect(veils(glass) == 0)
    }

    @Test func theBannerCastsThePopupShadow() throws {
        let card = Self.card()
        card.layout()
        let layer = try #require(card.layer)
        #expect(!layer.masksToBounds)
        #expect(layer.shadowOpacity > 0)
        #expect(layer.shadowPath != nil)
    }

    /// The second half of the same report: on macOS 26 the banner still drew a near-black 1 px
    /// line at its top and bottom (fleet capture, 60/255 over a 241/255 page). It floats on the
    /// overlay host, a clear window over the page's window, where Liquid Glass has nothing to
    /// refract and its lens bends the clear pixels into that line. It is the blur of what is
    /// behind its window instead.
    @Test func theBannerBlursThePageBehindItsWindowNeverLiquidGlass() throws {
        let glass = try #require(Self.card().glass)
        #expect(glass.samplesBehindWindow)
        #expect(glass.material != .liquidGlass)
        if glass.material == .vibrancy {
            let blur = try #require(glass.subviews.compactMap { $0 as? NSVisualEffectView }.first)
            #expect(blur.blendingMode == .behindWindow)
        }
    }

    @Test func aSurfaceThatPrefersTheBlurTakesItOverLiquidGlassButKeepsReduceTransparency() {
        let clear = ReduceTransparency(system: { false }, changes: NotificationCenter())
        let surface = OverlaySurfaceView(interactive: true, reduceTransparency: clear, tone: .neutralGlass(.dialog))
        surface.prefersBlurToLiquidGlass = true
        #expect(surface.material != .liquidGlass)
        let opaque = OverlaySurfaceView(interactive: true, reduceTransparency: .alwaysOpaque, tone: .neutralGlass(.dialog))
        opaque.prefersBlurToLiquidGlass = true
        #expect(opaque.material == .opaque)
    }
}
