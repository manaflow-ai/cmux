import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDesign
@testable import CmuxNextMacScreen
import CmuxNextPages
import CmuxNextRemoteView
import CmuxNextScreenshots
import CmuxNextTestSupport
import CmuxScreenKit
import CmuxTheme
import Foundation
import Testing

/// Leo 2026-11-21: "hey speaking of this screen sharing, we need far better ui/ux for our shit! our screen shared scren
/// look slike ass...". An agent's `cmux tab screenshot` of a share that failed ("The connection to Studio Mac mini
/// failed: the secure handshake timed out") was one flat gray image: the masked capture covered the whole Mac Screen
/// tab, its Couldn't connect card and Try Again included. Here the real pane, in a tab of the Mac Screen page, fails
/// through the link's own `ended` line (``MacScreenSession/linkEnded(_:)``, which the hub hears as a failed stream), and
/// the agent's capture (``AppWindowImage/maskedCapture(_:)``) shows the card; a live picture stays masked. The failed
/// capture is written to `mac-screen-masked-capture/failed-handshake.png` in the package (`cmux-ci run --artifact`).
@MainActor @Suite(.closesItsWindows, .serialized, .timeLimit(.minutes(1))) struct MacScreenMaskedCaptureTests {
    static let size = CGSize(width: 1280, height: 800)
    static let remotePixels = CGSize(width: 2560, height: 1600)

    struct Fixture {
        let window: NSWindow
        let pane: MacScreenPane
        let viewer: MacScreenHubViewer

        func close() {
            pane.close()
            window.orderOut(nil)
            window.close()
        }
    }

    /// The Mac Screen page's tab holding a real viewer pane (look A, Soft Blue dark) on a hub tab that streams.
    func fixture() async throws -> Fixture {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: Self.size.width, height: Self.size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        let root = NSView(frame: NSRect(origin: .zero, size: Self.size))
        root.wantsLayer = true
        root.appearance = window.appearance
        window.contentView = root
        let input = try AANestedGroupsGalleryTests.input("Soft Blue")
        _ = ThemeScope.app.store.apply(input)
        let scope = ThemeScope(level: .room)
        scope.setOverride(ThemeSpec("Soft Blue"), input: input, animated: false)
        scope.root(root)
        let hub = await AAMacScreenViewerGalleryTests.connectedHub()
        let viewer = MacScreenHubViewer(deviceID: "0b6c1a2e-3d4f-4a5b-8c9d-aabbccddeeff") { hub }
        viewer.phase = .streaming(sessionID: "masked-capture-session", scope: .full)
        let pane = MacScreenPane(hubDevice: viewer, name: "Studio Mac mini", preferences: ScreenPreferences(), viewerLook: .a)
        let tab = InternalPageView(key: "mask-mac-screen", page: .macScreen, content: pane.view)
        tab.frame = root.bounds
        tab.autoresizingMask = [.width, .height]
        root.addSubview(tab)
        window.orderFrontRegardless()
        return Fixture(window: window, pane: pane, viewer: viewer)
    }

    /// Lets the pane's observation tasks run, then lays out and draws it.
    func settle(_ fixture: Fixture) async {
        for _ in 0 ..< 100 { await Task.yield() }
        let view = fixture.pane.view
        view.chrome.toolbar.resolveColors()
        view.chrome.card.resolveColors()
        view.needsLayout = true
        fixture.window.contentView?.layoutSubtreeIfNeeded()
        fixture.window.contentView?.displayIfNeeded()
        CATransaction.flush()
    }

    @Test(.enabled("this host puts windows on screen") { await MaskedScreenshotTests.hostShowsWindows() })
    func aFailedShareShowsItsCardInAnAgentsCapture() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        let session = try #require(fixture.pane.session)
        // The connect was under way when `cmux rd connect` ended with the link's own failure.
        session.showPreviewState(phase: .connecting)
        session.linkEnded("link failed: the secure handshake timed out")
        await settle(fixture)
        guard case .failed = session.phase else {
            Issue.record("the session failed: \(session.phase)")
            return
        }
        guard case .streamFailed = fixture.viewer.phase else {
            Issue.record("the hub heard the stream fail: \(fixture.viewer.phase)")
            return
        }
        #expect(fixture.pane.model.card == .failed)
        #expect(fixture.pane.model.failedDetail == "The connection to Studio Mac mini failed: the secure handshake timed out")
        let card = fixture.pane.view.chrome.card
        try #require(!card.isHidden && card.frame.width > 0, "the pane shows the failed card")
        let cardRect = card.convert(card.bounds, to: nil)

        let (image, _, areas) = try await AppWindowImage.maskedCapture(fixture.window)
        let out = AANestedGroupsGalleryTests.packageRoot.appending(path: "mac-screen-masked-capture")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try AAGroupHeaderDensityGalleryTests.write(image, to: out.appending(path: "failed-handshake.png"))

        #expect(!areas.map(\.name).contains("page:mac-screen"), "the Mac Screen tab is not masked whole: \(areas.map(\.name))")
        let shot = MaskedScreenshotTests.Pixels(image)
        let inCard = shot.all(in: cardRect.insetBy(dx: 4, dy: 4), size: Self.size)
        #expect(!inCard.isEmpty)
        #expect(!inCard.contains(where: MaskedScreenshotTests.isMask), "no pixel of the card is masked")
        // The card draws its title, message and buttons: more than one flat fill.
        let distinct = Set(inCard.map { $0.red / 16 * 256 + $0.green / 16 * 16 + $0.blue / 16 })
        #expect(distinct.count > 4, "the card shows text and buttons, not a flat fill (\(distinct.count) shades)")
        let corner = shot.all(in: NSRect(x: 8, y: 8, width: 40, height: 40), size: Self.size)
        #expect(!corner.contains(where: MaskedScreenshotTests.isMask), "the pane's backdrop is not masked")
    }

    @Test(.enabled("this host puts windows on screen") { await MaskedScreenshotTests.hostShowsWindows() })
    func theOtherMacsPictureStaysMasked() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        let session = try #require(fixture.pane.session)
        session.showPreviewState(phase: .connected, frameSize: Self.remotePixels)
        fixture.pane.model.hasFrame = true
        await settle(fixture)
        let video = fixture.pane.view.video
        try #require(!video.frame.isEmpty, "the picture has its place")
        let pictureRect = video.convert(video.bounds, to: nil)
        // The picture's own pixels: red, a stand-in for the other Mac's screen.
        let pixels = NSView(frame: video.bounds)
        pixels.autoresizingMask = [.width, .height]
        pixels.wantsLayer = true
        pixels.layer?.backgroundColor = MaskedScreenshotTests.red
        video.addSubview(pixels)
        fixture.window.contentView?.displayIfNeeded()
        CATransaction.flush()

        let mask = ScreenshotMask.read(fixture.window, rules: .app)
        #expect(mask.areas.contains(ScreenshotMask.Area(name: "remote-screen", rect: pictureRect)))
        let (image, _, areas) = try await AppWindowImage.maskedCapture(fixture.window)
        #expect(areas.map(\.name).contains("remote-screen"))
        let shot = MaskedScreenshotTests.Pixels(image)
        let inPicture = shot.all(in: pictureRect, size: Self.size)
        #expect(!inPicture.isEmpty)
        #expect(inPicture.allSatisfy(MaskedScreenshotTests.isMask), "every pixel of the other Mac's picture is masked")
        #expect(!shot.everyPixel.contains(where: MaskedScreenshotTests.isRed), "no pixel of the picture survives anywhere")
    }

    @Test func theMacScreenTabIsShownAndItsPictureCovered() {
        let tab = InternalPageView(key: "mask-mac-screen-rule", page: .macScreen, content: NSView())
        #expect(!ScreenshotMask.covers(tab), "the Mac Screen tab's chrome and cards are shown")
        let video = RemoteVideoView()
        #expect(ScreenshotMask.covers(video), "another machine's picture is masked wherever it sits")
        #expect(ScreenshotMask.areaName(video) == "remote-screen")
    }
}
