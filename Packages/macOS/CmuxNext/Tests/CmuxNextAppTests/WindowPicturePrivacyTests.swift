import AppKit
@testable import CmuxNextApp
import CmuxNextBrowser
@testable import CmuxNextDaemon
import CmuxNextLaunch
import CoreGraphics
import Foundation
import Testing

/// The window pictures' privacy rules at the app layer that decides them: a page reopened for
/// protected media and a page that took Secure Input while the page captures ran are filled even when a picture of
/// them exists.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct WindowPicturePrivacyTests {
    static func picture() throws -> BrowserLaunchPictures.Picture {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: 8, height: 6, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 6))
        return BrowserLaunchPictures.Picture(image: try #require(context.makeImage()), paneSize: CGSize(width: 400, height: 300),
                                             pageFrame: CGRect(x: 0, y: 40, width: 400, height: 260))
    }

    /// Whether `source` comes out filled in the window's picture.
    static func isFilled(_ source: WindowPictureStore.Pane.Source?) -> Bool {
        guard let source, case .fill = WindowPictureStore.Pane.Content(source) else { return false }
        return true
    }

    /// Whether `source` comes out as its picture in the window's picture.
    static func isPlaced(_ source: WindowPictureStore.Pane.Source?) -> Bool {
        guard let source, case .placed = WindowPictureStore.Pane.Content(source) else { return false }
        return true
    }

    /// A tab that reopened in WebKit for protected media is filled, even with a picture of its page.
    @Test func aPageReopenedForProtectedMediaIsFilled() throws {
        let rig = BrowserLaunchPictureShotsTests.Rig()
        defer { rig.tearDown() }
        let tab = TabModel(TabSnapshot(surface: SurfaceID(rawValue: 7), kind: .browser))
        let page = rig.page(tab.id)
        _ = rig.pane(for: page)
        rig.cache.browserTabs.tabModel = { $0 == tab.id ? tab : nil }
        let picture = try Self.picture()

        #expect(Self.isPlaced(rig.cache.windowPictureSource(tab.id, picture: picture, secureInput: [])), "a plain page's picture was not placed")
        rig.cache.browserTabs.noteProtectedMediaReopen(tab)
        let window = try #require(page.contentView.window)
        #expect(rig.cache.withholdsLaunchPicture(tab.id, page: page, in: window, secureInput: []), "a protected-media page was not withheld")
        #expect(Self.isFilled(rig.cache.windowPictureSource(tab.id, picture: picture, secureInput: [])),
                "a protected-media page's picture reached the window's picture")
    }

    /// A Chromium page that took Secure Input after the quit began (while the page captures ran) is filled when the
    /// window's picture is composed, even with a picture of its page; the pages of the quit's start stay withheld.
    @Test func aPageHoldingSecureInputOnlyAtComposeIsFilled() throws {
        let rig = BrowserLaunchPictureShotsTests.Rig()
        defer { rig.tearDown() }
        let chromium = rig.page("tab_password")
        chromium.presentation = .childWindow
        _ = rig.pane(for: chromium)
        let pageWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
        pageWindow.isReleasedWhenClosed = false
        defer { pageWindow.close() }
        rig.window.addChildWindow(pageWindow, ordered: .above)
        let picture = try Self.picture()

        let quitBegan: Set<String> = ["tab_earlier"]
        let noSecureInput = rig.cache.composeSecureInputPages(quitBegan: quitBegan, secureInput: false, keyWindow: pageWindow)
        #expect(noSecureInput == quitBegan)
        #expect(Self.isPlaced(rig.cache.windowPictureSource("tab_password", picture: picture, secureInput: noSecureInput)))

        let atCompose = rig.cache.composeSecureInputPages(quitBegan: quitBegan, secureInput: true, keyWindow: pageWindow)
        #expect(atCompose == ["tab_earlier", "tab_password"], "the Secure Input that began after the quit started went unseen")
        #expect(Self.isFilled(rig.cache.windowPictureSource("tab_password", picture: picture, secureInput: atCompose)),
                "a page holding Secure Input at compose time reached the window's picture")
    }

    /// A page in no window is withheld: it is filled, never placed.
    @Test func aPageInNoWindowIsFilled() throws {
        let rig = BrowserLaunchPictureShotsTests.Rig()
        defer { rig.tearDown() }
        _ = rig.page("tab_offscreen")
        #expect(Self.isFilled(rig.cache.windowPictureSource("tab_offscreen", picture: try Self.picture(), secureInput: [])))
        #expect(rig.cache.windowPictureSource("tab_none", picture: nil, secureInput: []) == nil, "a tab with no page got a browser source")
    }
}
