import AppKit
@testable import CmuxNextApp
import CmuxNextBrowser
@testable import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextInput
import CmuxNextLaunch
@testable import CmuxNextTabs
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// The browser pages' pictures from the last quit, at the layer that decides them: the quit takes
/// no picture of an incognito page (an off-the-record profile, an incognito workspace) or of a page holding Secure
/// Input, a Chromium page included (it holds the keyboard as a key child window); and at launch a Chromium page,
/// drawn in its own window over the pane, keeps a hole over the picture until its first content frame.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct BrowserLaunchPictureShotsTests {
    static let work = BackgroundWork(label: "test.browser-launch-picture-shots")

    @Test func anIncognitoPageIsNeverWritten() async throws {
        let rig = Rig()
        defer { rig.tearDown() }
        let incognitoProfile = rig.cache.chromium.stores.offTheRecord.begin()
        let shown = rig.page("tab_shown"), offTheRecord = rig.page("tab_otr", profile: incognitoProfile)
        let incognitoWorkspace = rig.page("tab_incognito")
        rig.cache.browserTabs.isIncognitoTab = { $0 == "tab_incognito" }
        let panes = [shown, offTheRecord, incognitoWorkspace].map { rig.pane(for: $0) }

        let shots = await rig.cache.launchPictureShots(panes, secureInput: [])
        #expect(shots.map(\.key) == ["tab_shown"], "an incognito page was pictured")
        #expect(offTheRecord.snapshotCount == 0 && incognitoWorkspace.snapshotCount == 0, "an incognito page's pixels were read")

        let directory = Self.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        await BrowserLaunchPictures(directory: directory, work: Self.work).save(shots)
        let profile = BrowserProfileID.default.rawValue.uuidString
        #expect(Self.files(under: directory) == [profile, "\(profile)/pictures.json", "\(profile)/tab_shown.jpg"],
                "an incognito page was written")
        let index = try String(contentsOf: directory.appending(path: "\(profile)/pictures.json"), encoding: .utf8)
        #expect(!index.contains("tab_otr") && !index.contains("tab_incognito"), "the index names an incognito page")
    }

    /// A Chromium page with a focused password field: the cmux window's first responder is not in the page (its
    /// own window is key), and a quit dialog may take the keyboard before the pictures are taken. The quit reads
    /// the Secure Input pages first; their pictures are never taken.
    @Test func aChromiumPageHoldingSecureInputIsNeverPictured() async throws {
        let rig = Rig()
        defer { rig.tearDown() }
        let chromium = rig.page("tab_password"), webKit = rig.page("tab_other")
        chromium.presentation = .childWindow
        let pageWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
        pageWindow.isReleasedWhenClosed = false
        defer { pageWindow.close() }
        rig.window.addChildWindow(pageWindow, ordered: .above)
        let panes = [chromium, webKit].map { rig.pane(for: $0) }

        #expect(rig.cache.secureInputPages(secureInput: false, keyWindow: pageWindow).isEmpty)
        let secureInput = rig.cache.secureInputPages(secureInput: true, keyWindow: pageWindow)
        #expect(secureInput == ["tab_password"], "the Chromium page's password field went unseen")
        let shots = await rig.cache.launchPictureShots(panes, secureInput: secureInput)
        #expect(shots.map(\.key) == ["tab_other"])
        #expect(chromium.snapshotCount == 0, "the password page's pixels were read")
    }

    /// The picture is up before the page exists; the Chromium page made after it keeps a hole over all of itself
    /// while the picture shows, and gives it up at its first content frame, when the picture goes.
    @Test func aChromiumPageDoesNotCoverThePictureBeforeItsFirstContentFrame() async throws {
        let rig = Rig()
        defer { rig.tearDown() }
        let fixture = try await PictureFixture(rig)
        defer { fixture.tearDown() }
        #expect(rig.cache.showLaunchPicture("tab_a", in: fixture.pane, hold: fixture.hold, reveal: fixture.reveal))
        let shown = try #require(fixture.pane.launchImageView as? BrowserLaunchPictureView)
        #expect(shown.showsPicture)

        let page = rig.page("tab_a")
        page.presentation = .childWindow
        #expect(rig.cache.showLaunchPicture("tab_a", in: fixture.pane, hold: fixture.hold, reveal: fixture.reveal))
        #expect(page.isPageCovered, "the page's window draws over the picture")
        page.simulateFirstContentFrame()
        #expect(fixture.pane.launchImageView == nil, "the picture outlived the page's first content")
        #expect(!page.isPageCovered, "the page stayed hidden after the picture went")
    }

    /// The picture's limit (or a switch to another tab) takes it down before the page shows content: the page
    /// shows again.
    @Test func aPictureTakenDownEarlyGivesThePageBack() async throws {
        let rig = Rig()
        defer { rig.tearDown() }
        let fixture = try await PictureFixture(rig)
        defer { fixture.tearDown() }
        let page = rig.page("tab_a")
        page.presentation = .childWindow
        #expect(rig.cache.showLaunchPicture("tab_a", in: fixture.pane, hold: fixture.hold, reveal: fixture.reveal))
        #expect(page.isPageCovered)
        fixture.pane.clearLaunchImage(.visiblePaneTimedOut)
        #expect(!page.isPageCovered, "the page stayed hidden after the picture went")
    }

    static func folder() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "browser-launch-picture-shots-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    /// Every path under `directory`, relative to it, sorted.
    static func files(under directory: URL) -> [String] {
        ((try? FileManager.default.subpathsOfDirectory(atPath: directory.path)) ?? []).sorted()
    }

    /// The app's tab content cache, and a window whose panes show its mock pages (each in a content area of its own).
    @MainActor final class Rig {
        let cache = TabContentCache(daemon: DaemonService(), chromium: ChromiumEngineSlot(CEFEngine(layout: nil, stores: .inMemory(), signInCallbacks: CEFSignInCallbacks(), input: InputEventTap())), fileInput: NoFileInput(), mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        let engine = MockBrowserEngine(kind: .cef)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: false)
        private var keys: [String] = []

        init() {
            window.isReleasedWhenClosed = false
            window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        }

        /// A page of tab `key` in `profile`, in the cache.
        func page(_ key: String, profile: BrowserProfileID = .default) -> MockBrowserTab {
            let page = engine.makeMockTab(BrowserTabConfiguration(id: BrowserTabID(rawValue: key), profile: profile))
            cache.install(page, for: key)
            keys.append(key)
            return page
        }

        /// `page` shown in a content area of the window, as the quit lists it.
        func pane(for page: MockBrowserTab) -> (key: String, host: NSView) {
            let host = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
            page.contentView.frame = NSRect(x: 0, y: 0, width: 400, height: 260)
            host.addSubview(page.contentView)
            window.contentView?.addSubview(host)
            return (page.id.rawValue, host)
        }

        func tearDown() {
            for key in keys { cache.release(key) }
            window.contentView = nil
            window.close()
        }
    }

    /// A pane in the rig's window and the last quit's picture of tab `tab_a` at its content area's size, read and
    /// handed to the cache.
    @MainActor final class PictureFixture {
        let scheduler = StartupTestScheduler()
        let reveal = LaunchReveal(deadline: .seconds(60))
        let hold: LaunchImageHold
        let pane: PaneContentView
        let directory = BrowserLaunchPictureShotsTests.folder()

        init(_ rig: Rig) async throws {
            hold = LaunchImageHold(startup: scheduler.startup)
            pane = .testing(stripModel: TabStripModel(tabs: [TabItem(id: TabID("tab_a"), title: "A")]), reveal: reveal)
            pane.frame = rig.window.contentLayoutRect
            rig.window.contentView?.addSubview(pane)
            pane.layoutSubtreeIfNeeded()
            let size = pane.contentHost.bounds.size
            try #require(size.width > 0 && size.height > 0)
            let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
            let context = try #require(CGContext(data: nil, width: 8, height: 6, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                                 bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            context.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 6))
            let picture = BrowserLaunchPictures.Picture(image: try #require(context.makeImage()), paneSize: size,
                                                        pageFrame: CGRect(origin: .zero, size: size))
            await BrowserLaunchPictures(directory: directory, work: BrowserLaunchPictureShotsTests.work)
                .save([BrowserLaunchPictures.Shot(key: "tab_a", profile: BrowserProfileID.default.rawValue, picture: picture)])
            let pictures = BrowserLaunchPictures(directory: directory, work: BrowserLaunchPictureShotsTests.work)
            pictures.prefetch()
            await pictures.readFinished()
            rig.cache.launchPictures = pictures
        }

        func tearDown() {
            pane.clearLaunchImage()
            pane.removeFromSuperview()
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
