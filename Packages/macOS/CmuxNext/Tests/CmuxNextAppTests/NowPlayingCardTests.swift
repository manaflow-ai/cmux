import AppKit
@testable import CmuxNextApp
import CmuxNextBrowser
import CmuxNextDesign
@testable import CmuxNextNowPlaying
import CmuxNextSettings
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Foundation
import Observation
import Testing

/// The sidebar's Now Playing card (cx-ouoxo, behind `sidebar.nowPlaying.enabled`), driven by a fake Now
/// Playing source through the same feed and intent route the app uses: it shows what plays with its
/// artwork and controls, its controls and scrubber reach the source, a seek the source ignores does
/// not freeze the scrubber, a tab's artwork that failed to load comes in later, it draws in the
/// terminal theme, nothing on it moves under Reduce Motion, and it is there only while Now Playing is on.
@MainActor @Suite(.serialized, .closesItsWindows) struct NowPlayingCardTests {
    @Observable final class FakeSource: NowPlayingSource {
        var nowPlaying: SidebarNowPlaying?
        @ObservationIgnored var commands: [SidebarNowPlayingCommand] = []
        func perform(_ command: SidebarNowPlayingCommand) { commands.append(command) }
    }

    @Observable final class Flag {
        var on: Bool
        init(_ on: Bool) { self.on = on }
    }

    static let labels = SidebarNowPlaying.Labels(play: "Play", pause: "Pause", previous: "Previous Track", next: "Next Track")

    /// An 8 pt square of color, as PNG.
    static func artwork() -> Data {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8, samplesPerPixel: 4,
                                      hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for x in 0..<8 { for y in 0..<8 { bitmap.setColor(NSColor(srgbRed: 0.2, green: 0.6, blue: 0.7, alpha: 1), atX: x, y: y) } }
        return bitmap.representation(using: .png, properties: [:])!
    }

    static func track(playing: Bool = true) -> SidebarNowPlaying {
        SidebarNowPlaying(title: "Weightless", artist: "Marconi Union", artwork: artwork(), isPlaying: playing, position: 60,
                          duration: 480, positionDate: Date(), canPrevious: true, canNext: true, labels: labels)
    }

    /// A tab's video, as the tab source reports it.
    static func video(floating: Bool = false) -> SidebarNowPlaying {
        var video = track()
        video.site = "youtube.com"
        video.canPictureInPicture = true
        video.isPictureInPicture = floating
        video.labels = SidebarNowPlaying.Labels(play: "Play", pause: "Pause", previous: "Previous Track", next: "Next Track",
                                                pictureInPicture: "Picture in Picture", exitPictureInPicture: "Exit Picture in Picture")
        return video
    }

    struct Harness {
        let source: FakeSource
        let flag: Flag
        let model: SidebarModel
        let sidebar: SidebarView
        let window: NSWindow
        let feed: Task<Void, Never>
        var card: SidebarNowPlayingCardView { sidebar.nowPlayingCardView }

        /// Waits for the sidebar to show (or hide) the card; it follows the model on a task.
        func cardShows(_ shows: Bool = true, within timeout: Duration = .seconds(10)) async {
            let deadline = ContinuousClock.now + timeout
            while (card.isHidden || card.frame.isEmpty) == shows, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(5))
                sidebar.needsLayout = true
                sidebar.layoutSubtreeIfNeeded()
            }
        }

        func close() {
            feed.cancel()
            window.close()
        }
    }

    func make(enabled: Bool = true, scope: ThemeScope? = nil, playing: Bool = true) async -> Harness {
        _ = NSApplication.shared
        let source = FakeSource()
        source.nowPlaying = Self.track(playing: playing)
        let flag = Flag(enabled)
        let model = SidebarModel()
        model.onIntent = { [source] intent in source.handle(intent) }
        let sidebar = SidebarView(model: model, design: DesignSettings())
        scope?.root(sidebar)
        let width = Metrics.sidebarWidth
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: width, height: 640), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = sidebar
        sidebar.frame = NSRect(x: 0, y: 0, width: width, height: 640)
        window.orderFrontRegardless()
        let feed = model.followNowPlaying(source, enabled: { flag.on })
        let harness = Harness(source: source, flag: flag, model: model, sidebar: sidebar, window: window, feed: feed)
        await harness.cardShows(enabled)
        return harness
    }

    /// With no cmux.json, a page playing sound puts no media card in the sidebar's footer
    /// (Lawrence 2026-10-19: the card at the bottom left was unwanted; the tab's speaker is enough).
    @Test func theSidebarFooterHasNoMediaCardByDefault() async {
        let defaults = CmuxConfigSnapshot.parse(.object([:]), validDensities: [], validMetrics: [])
        let h = await make(enabled: defaults.nowPlaying.enabled)
        defer { h.close() }
        #expect(h.source.nowPlaying?.isPlaying == true, "the fake source must be playing for this check")
        // Give the feed the same window a shown card gets to appear, then check it never did.
        await h.cardShows(true, within: .milliseconds(500))
        #expect(h.model.nowPlaying == nil, "the feed passed the track to the sidebar by default")
        #expect(h.card.isHidden || h.card.frame.isEmpty, "a media card \(h.card.frame) shows in the sidebar footer by default")
        #expect(h.sidebar.subviews.contains { $0 is SidebarNowPlayingCardView && !$0.isHidden && !$0.frame.isEmpty } == false)
    }

    @Test func theCardShowsWhatPlaysWithItsArtworkAndControls() async throws {
        let h = await make()
        defer { h.close() }
        try #require(!h.card.isHidden && !h.card.frame.isEmpty, "no Now Playing card while a track plays")
        #expect(h.sidebar.bounds.contains(h.card.frame), "the card \(h.card.frame) is not inside the sidebar \(h.sidebar.bounds)")
        #expect(h.card.titleLabel.stringValue == "Weightless")
        #expect(h.card.artistLabel.stringValue == "Marconi Union")
        #expect(h.card.artworkView.image != nil, "no artwork")
        #expect(h.card.playPauseButton.accessibilityLabel() == "Pause", "a playing track offers Pause")
        #expect(h.card.previousButton.accessibilityLabel() == "Previous Track")
        #expect(h.card.nextButton.accessibilityLabel() == "Next Track")
        #expect(!h.card.scrubber.isHidden && h.card.scrubber.accessibilityRole() == .slider, "no scrubber")
        for view in [h.card.titleLabel, h.card.artistLabel, h.card.artworkView, h.card.scrubber,
                     h.card.previousButton, h.card.playPauseButton, h.card.nextButton] as [NSView] {
            #expect(h.card.bounds.contains(view.frame) && !view.frame.isEmpty, "\(type(of: view)) at \(view.frame) is not on the card")
        }
    }

    /// A tab's video, as macOS's card shows it: the site above the title, and Picture in Picture past
    /// the transport, which reaches the source and reads as Exit while the video floats. A track that
    /// is not a video has no such button.
    @Test func aVideoShowsItsSiteAndPictureInPictureReachesTheSource() async throws {
        let h = await make()
        defer { h.close() }
        try #require(!h.card.isHidden, "no Now Playing card while a track plays")
        #expect(h.card.pictureInPictureButton.isHidden, "a track that is not a video offers Picture in Picture")
        #expect(h.card.siteLabel.isHidden, "a track with no site shows a site line")
        h.source.nowPlaying = Self.video()
        try await PasswordManagerRouteTests.until({ h.card.nowPlaying?.canPictureInPicture == true }, within: .seconds(6)) {
            "the card never showed the video"
        }
        h.sidebar.needsLayout = true
        h.sidebar.layoutSubtreeIfNeeded()
        #expect(h.card.siteLabel.stringValue == "youtube.com" && !h.card.siteLabel.isHidden, "no site line")
        #expect(h.card.siteLabel.frame.maxY <= h.card.titleLabel.frame.minY, "the site \(h.card.siteLabel.frame) is not above the title")
        let pip = h.card.pictureInPictureButton
        #expect(!pip.isHidden && !pip.frame.isEmpty && h.card.bounds.contains(pip.frame), "Picture in Picture at \(pip.frame) is not on the card")
        #expect(pip.frame.minX > h.card.nextButton.frame.maxX, "Picture in Picture is not past Next")
        #expect(pip.accessibilityLabel() == "Picture in Picture")
        _ = pip.sendAction(pip.action, to: pip.target)
        #expect(h.source.commands.last == .pictureInPicture, "the source got \(h.source.commands)")
        h.source.nowPlaying = Self.video(floating: true)
        try await PasswordManagerRouteTests.until({ h.card.nowPlaying?.isPictureInPicture == true }, within: .seconds(6)) {
            "the card never saw the video float"
        }
        #expect(pip.accessibilityLabel() == "Exit Picture in Picture")
    }

    @Test func theControlsAndTheScrubberReachTheSource() async throws {
        let h = await make()
        defer { h.close() }
        try #require(!h.card.isHidden, "no Now Playing card while a track plays")
        // sendAction, not performClick: performClick leaves AppKit work queued that can outlive the
        // closed window on a display host and take the test process down in a later test.
        for button in [h.card.playPauseButton, h.card.nextButton, h.card.previousButton] {
            #expect(button.isEnabled, "\(button.accessibilityLabel() ?? "a control") is disabled while a track plays")
            _ = button.sendAction(button.action, to: button.target)
        }
        // A click a quarter of the way along the scrubber seeks to a quarter of the track.
        let scrubber = h.card.scrubber
        let point = scrubber.convert(NSPoint(x: scrubber.bounds.width / 4, y: scrubber.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                                        windowNumber: h.window.windowNumber, context: nil, eventNumber: 0,
                                                        clickCount: 1, pressure: 1))
            if type == .leftMouseDown { scrubber.mouseDown(with: event) } else { scrubber.mouseUp(with: event) }
        }
        let commands = h.source.commands
        #expect(Array(commands.prefix(3)) == [.playPause, .next, .previous], "the source got \(commands)")
        guard commands.count == 4, case .seek(let seconds) = commands[3] else {
            Issue.record("the scrubber did not seek: \(commands)")
            return
        }
        #expect(abs(seconds - 120) < 2, "a quarter of 480 s is 120 s, the scrubber asked for \(seconds)")
    }

    /// Clicks the scrubber `fraction` of the way along.
    func click(_ h: Harness, at fraction: CGFloat) throws {
        let scrubber = h.card.scrubber
        let point = scrubber.convert(NSPoint(x: scrubber.bounds.width * fraction, y: scrubber.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                                        windowNumber: h.window.windowNumber, context: nil, eventNumber: 0,
                                                        clickCount: 1, pressure: 1))
            if type == .leftMouseDown { scrubber.mouseDown(with: event) } else { scrubber.mouseUp(with: event) }
        }
    }

    @Test func aSeekTheSourceIgnoresLetsTheScrubberRunOnFromWhereItPlays() async throws {
        let h = await make()
        defer { h.close() }
        try #require(!h.card.isHidden, "no Now Playing card while a track plays")
        let scrubber = h.card.scrubber
        let fraction = { scrubber.fill.bounds.width / max(1, scrubber.bounds.width) }
        // Three quarters along asks for 360 s. The source ignores it and reports nothing new: it
        // still plays from 60 s, an eighth of the track.
        try click(h, at: 0.75)
        guard case .seek(let seconds)? = h.source.commands.last, abs(seconds - 360) < 2 else {
            Issue.record("the scrubber did not seek to 360 s: \(h.source.commands)")
            return
        }
        #expect(fraction() > 0.7, "the scrubber does not show the point it was dragged to (\(fraction()))")
        try await PasswordManagerRouteTests.until({ fraction() < 0.2 }, within: .seconds(6)) {
            "the scrubber stays at \(fraction()) of the track after a seek the source ignored, not where it plays"
        }
    }

    @Test func aTabsArtworkThatDidNotLoadComesInLater() async throws {
        let tab = MockBrowserEngine(kind: .cef).makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://example.com/listen")))
        // The name never resolves, so the first fetch fails. It is https on a public name: the favicon
        // guard refuses local and plain-http URLs outright, cached or not (70976f18493).
        let art = try #require(URL(string: "https://cover-\(UUID().uuidString).invalid/cover.png"))
        let media = BrowserMediaState(title: "Weightless", artworkURL: art, isPlaying: true, position: 60, duration: 480)
        let source = BrowserTabsNowPlaying()
        source.artworkRetry = .milliseconds(200)
        source.follow(sessions: { [NowPlayingSession(tab: tab.id, media: media)] }, tab: { _ in tab })
        // Read the way the card is fed: the model reads the source again only when it changes.
        let model = SidebarModel()
        let following = model.followNowPlaying(source, enabled: { true })
        defer { following.cancel() }
        try await PasswordManagerRouteTests.until({ model.nowPlaying != nil }, within: .seconds(6)) { "the card never shows the tab's track" }
        try await Task.sleep(for: .seconds(1))
        #expect(model.nowPlaying?.artwork == nil, "artwork from a fetch that cannot succeed")
        // Now the image is there (a later fetch of the same URL gets it).
        _ = BrowserFaviconLoader.shared.store(Self.artwork(), at: art, profile: tab.profileID)
        try await PasswordManagerRouteTests.until({ model.nowPlaying?.artwork != nil }, within: .seconds(6)) {
            "the card never shows the tab's artwork after its first fetch failed"
        }
    }

    @Test func theCardDrawsInTheTerminalTheme() async throws {
        let scope = try ThemedOverlayColorsTests.purpleRoom()
        let h = await make(scope: scope)
        defer { h.close() }
        try #require(!h.card.isHidden, "no Now Playing card while a track plays")
        let (primary, secondary) = scope.perform { (Palette.textPrimary, Palette.textSecondary) }
        func same(_ a: NSColor?, _ b: NSColor) -> Bool {
            guard let a = a?.usingColorSpace(.sRGB), let b = b.usingColorSpace(.sRGB) else { return false }
            return [a.redComponent - b.redComponent, a.greenComponent - b.greenComponent, a.blueComponent - b.blueComponent,
                    a.alphaComponent - b.alphaComponent].allSatisfy { abs($0) < 0.01 }
        }
        #expect(same(h.card.titleLabel.textColor, primary), "the title is \(String(describing: h.card.titleLabel.textColor)), not the theme's text \(primary)")
        #expect(same(h.card.artistLabel.textColor, secondary), "the artist is not the theme's secondary text \(secondary)")
        #expect(h.card.subviews.first is CardSurfaceView, "the card is not on the sidebar cards' surface")
    }

    @Test func nothingOnTheCardMovesUnderReduceMotion() throws {
        _ = NSApplication.shared
        let card = SidebarNowPlayingCardView(frame: NSRect(x: 0, y: 0, width: 216, height: SidebarNowPlayingCardView.height(for: Self.track())))
        let window = NSWindow(contentRect: card.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = card
        window.orderFrontRegardless()
        /// Every animation on the card that slides (anything but a discrete step) or repeats.
        func sliding() -> [String] {
            func animated(_ layer: CALayer) -> [String] {
                let own = (layer.animationKeys() ?? []).filter { key in
                    guard let animation = layer.animation(forKey: key) else { return false }
                    let steps = (animation as? CAKeyframeAnimation)?.calculationMode == .discrete
                    return !steps || animation.repeatCount > 0 || animation.autoreverses
                }
                return own + (layer.sublayers ?? []).flatMap(animated)
            }
            func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
            return views(card).compactMap(\.layer).flatMap(animated)
        }
        card.scrubber.reduceMotionOverride = true
        card.levels.reduceMotionOverride = true
        card.configure(Self.track())
        card.isHidden = false
        card.layoutSubtreeIfNeeded()
        #expect(sliding().isEmpty, "under Reduce Motion the playing card slides or loops: \(sliding())")
        // The scrubber still shows where the track is: an eighth of the way.
        let fraction = card.scrubber.fill.bounds.width / max(1, card.scrubber.bounds.width)
        #expect(abs(fraction - 0.125) < 0.02, "the scrubber shows \(fraction) of the track, not 60 s of 480 s")
        // VoiceOver hears where it is now, not where it was when the card last changed.
        let spoken = card.scrubber.accessibilityValue() as? String ?? ""
        #expect(spoken.contains("1:00") && spoken.hasSuffix("8:00"), "VoiceOver hears \(spoken)")
    }

    @Test func theCardIsThereOnlyWhileNowPlayingIsOn() async throws {
        let h = await make(enabled: false)
        defer { h.close() }
        // Long enough for the feed's first pass (the same feed shows the card within milliseconds when on).
        try await Task.sleep(for: .milliseconds(300))
        h.sidebar.layoutSubtreeIfNeeded()
        #expect(h.model.nowPlaying == nil, "the feed passed the track on with Now Playing off")
        #expect(h.card.isHidden || h.card.frame.isEmpty, "the card shows with Now Playing off")
        #expect(NowPlayingSettings.enabledDefault == false, "Now Playing is shown by default")
        h.flag.on = true
        await h.cardShows()
        #expect(!h.card.isHidden && !h.card.frame.isEmpty, "turning Now Playing on shows no card")
        h.flag.on = false
        await h.cardShows(false)
        #expect(h.card.isHidden || h.card.frame.isEmpty, "turning Now Playing off leaves the card")
        h.flag.on = true
        await h.cardShows()
        h.source.nowPlaying = nil
        await h.cardShows(false)
        #expect(h.card.isHidden || h.card.frame.isEmpty, "the card stays after the source stops")
    }
}
