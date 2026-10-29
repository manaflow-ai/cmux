import AppKit
@testable import CmuxNextDesign
import Foundation
import Testing
import CmuxNextWakeups

/// The glass feed evaluates no script per frame of a motion: a page's
/// place in its window is pushed when it is final, at a render-server spring's start, at a spring's landing,
/// when a move of its pane ended, at a live window resize's end, and for a new size at rest. Frame and bounds
/// changes of the page or its ancestors push nothing by themselves, and the feed observes no notification.
@MainActor @Suite struct GlassBackdropFeedTests {
    /// A feed over a shown window's page, with its own frames and live-resize state.
    @MainActor
    private struct Rig {
        let window: GlassFeedWindow
        let feed: GlassBackdropFeed
        let frames: FrameScheduler
        let scripts: Scripts
        let resize: LiveResize
        let stills: GlassBackdropImages
        private var timestamp = 0.0

        init(art: URL, mode: @escaping @MainActor () -> GlassLensMode = { .lens }) async throws {
            let stills = GlassBackdropImages(maxPixelSize: 64)
            let resize = LiveResize()
            let window = try await GlassFeedWindow(art: art, store: BackdropImageStore(maxPixelSize: 64), stills: stills, own: .visible,
                                                   liveResize: { _ in resize.isOn })
            let frames = FrameScheduler.testing(mediaTime: { 500 }) { _ in GlassFeedLink() }
            let scripts = Scripts()
            self.window = window
            self.frames = frames
            self.scripts = scripts
            self.resize = resize
            self.stills = stills
            feed = GlassBackdropFeed(host: window.page, zoom: { 1 }, images: stills, mode: mode,
                                     scheduler: { _ in frames }, liveResize: { _ in resize.isOn }) { scripts.all.append($0) }
        }

        /// One display frame.
        mutating func frame() {
            timestamp += 1
            frames.frameDidFire(timestamp: timestamp, refreshInterval: 1.0 / 60)
        }

        /// The rect a page with nothing yet would get for the page's place now.
        func rectNow() -> GlassBackdropRect? {
            let probe = GlassBackdropFeed(host: window.page, zoom: { 1 }, images: stills, mode: { .lens },
                                          scheduler: { _ in frames }) { _ in }
            probe.refresh(newDocument: true)
            return probe.sent?.rect
        }
    }

    /// A strip camera or a pan moves the page every frame and pushes nothing; the end of the move
    /// (`PanePlacementFollowing`) pushes its place once, without the image.
    @Test func aPageMovingEveryFrameIsPushedOnceWhenTheMoveEnds() async throws {
        let art = try GlassBackdropTests.artFile()
        defer { try? FileManager.default.removeItem(at: art.deletingLastPathComponent()) }
        var rig = try await Rig(art: art)
        defer { rig.window.window.close() }
        rig.feed.refresh(newDocument: true)
        #expect(rig.scripts.all.count == 1, "the new document got no still")

        for step in 1...20 {
            rig.window.page.frame.origin.x = 20 + CGFloat(step) // the page moves on the strip camera
            rig.window.content.frame.origin.y = CGFloat(step) // and its ancestor with it
            rig.frame()
        }
        #expect(rig.scripts.all.count == 1, "frames of the move evaluated \(rig.scripts.all.count - 1) scripts")

        rig.feed.placementSettled()
        rig.frame()
        rig.frame()
        #expect(rig.scripts.all.count == 2, "the end of the move pushed \(rig.scripts.all.count - 1) scripts, not one")
        #expect(rig.scripts.all.last?.contains("\"rect\"") == true)
        #expect(rig.scripts.all.last?.contains("\"image\"") == false, "a move resent the image")
        #expect(rig.feed.sent?.rect == rig.rectNow(), "the push did not carry the place the move ended at")
    }

    /// An origin-only move at rest (a column close with no animation) pushes once when the
    /// layout says the place settled; in a pane motion or a live resize the settle waits for their end.
    @Test func aMoveAtRestPushesOnceAndOneInMotionWaits() async throws {
        let art = try GlassBackdropTests.artFile()
        defer { try? FileManager.default.removeItem(at: art.deletingLastPathComponent()) }
        var rig = try await Rig(art: art)
        defer { rig.window.window.close() }
        rig.feed.refresh(newDocument: true)

        rig.window.page.frame.origin.x = 30
        rig.feed.placementSettled()
        rig.feed.placementSettled()
        rig.frame()
        #expect(rig.scripts.all.count == 2, "a move at rest pushed \(rig.scripts.all.count - 1) scripts, not one")
        #expect(rig.feed.sent?.rect == rig.rectNow())

        rig.resize.isOn = true
        rig.window.page.frame.origin.x = 10
        rig.feed.placementSettled()
        rig.frame()
        #expect(rig.scripts.all.count == 2, "a settle in a live resize pushed")
        rig.resize.isOn = false

        let placement = SpringingPlacement(frame: rig.window.content.bounds)
        rig.window.content.addSubview(placement)
        placement.addSubview(rig.window.page)
        rig.feed.placementSettled()
        rig.frame()
        #expect(rig.scripts.all.count == 2, "a settle in a pane motion pushed")
    }

    /// A render-server spring places the page at rest in the key's turn (`PaneHostView.placeAtRest`): the push
    /// at its start carries the rest, and the landing sends nothing. A CPU spring's frame is still on its way
    /// at its start: only the landing pushes, with the rest. Either way at most two scripts per spring.
    @Test func aSpringPushesTheRestPlaceAtMostTwice() async throws {
        let art = try GlassBackdropTests.artFile()
        defer { try? FileManager.default.removeItem(at: art.deletingLastPathComponent()) }
        var rig = try await Rig(art: art)
        defer { rig.window.window.close() }
        rig.feed.refresh(newDocument: true)
        let page = rig.window.page
        let placement = SpringingPlacement(frame: rig.window.content.bounds)
        rig.window.content.addSubview(placement)
        placement.addSubview(page)

        // On the render server: announced, then the frame is set once, to rest.
        placement.onRenderServer = true
        rig.feed.layoutWillRest()
        page.frame = NSRect(x: 160, y: 20, width: 140, height: 80)
        rig.feed.hostDidLayout()
        rig.frame()
        #expect(rig.scripts.all.count == 2, "the render-server spring's start pushed no place")
        #expect(rig.feed.sent?.rect == rig.rectNow(), "the start's push is not the rest place")
        for _ in 1...10 { rig.frame() }
        placement.restOffset = .zero
        rig.feed.landed()
        rig.frame()
        #expect(rig.scripts.all.count == 2, "a render-server spring evaluated \(rig.scripts.all.count - 1) scripts")

        // On the CPU: the start pushes nothing (its frame is the first frame's), the landing pushes the rest.
        placement.onRenderServer = false
        placement.restOffset = CGVector(dx: -100, dy: 0)
        page.frame.origin.x = 150
        rig.feed.layoutWillRest()
        rig.frame()
        #expect(rig.scripts.all.count == 2, "the CPU spring's start pushed a place the page is only passing")
        for step in 1...10 {
            page.frame.origin.x = 150 - CGFloat(step * 10)
            page.frame.size.width = 140 - CGFloat(step * 2)
            rig.feed.hostDidLayout()
            rig.frame()
        }
        #expect(rig.scripts.all.count == 2, "the CPU spring's frames evaluated \(rig.scripts.all.count - 2) scripts")
        placement.restOffset = .zero
        rig.feed.landed()
        rig.frame()
        #expect(rig.scripts.all.count == 3, "a CPU spring evaluated \(rig.scripts.all.count - 2) scripts, not one")
        #expect(rig.feed.sent?.rect == rig.rectNow(), "the landing's push is not the rest place")
    }

    /// A live window resize lays the page out and resizes the art every frame and pushes nothing; its end
    /// pushes once.
    @Test func aWindowResizePushesOnceAtItsEnd() async throws {
        let art = try GlassBackdropTests.artFile()
        defer { try? FileManager.default.removeItem(at: art.deletingLastPathComponent()) }
        var rig = try await Rig(art: art)
        defer { rig.window.window.close() }
        rig.feed.refresh(newDocument: true)

        rig.resize.isOn = true
        for step in 1...20 {
            rig.window.content.frame.size.width = 320 + CGFloat(step * 4)
            rig.window.backdrop.setFrameSize(NSSize(width: 320 + CGFloat(step * 4), height: 200))
            rig.window.page.frame.size.width = 120 + CGFloat(step * 2)
            rig.feed.hostDidLayout()
            rig.frame()
        }
        #expect(rig.scripts.all.count == 1, "the resize's frames evaluated \(rig.scripts.all.count - 1) scripts")

        rig.resize.isOn = false
        rig.window.backdrop.viewDidEndLiveResize() // AppKit tells every view in the window
        rig.frame()
        rig.frame()
        #expect(rig.scripts.all.count == 2, "the resize's end pushed \(rig.scripts.all.count - 1) scripts, not one")
        #expect(rig.feed.sent?.rect == rig.rectNow(), "the resize's end did not push the place it ended at")
    }

    /// The art taking a new size at rest (a programmatic window resize, full screen) moves the page's rect; in a
    /// pane motion (a pane's own backdrop on a CPU spring) it waits for the landing.
    @Test func theArtsNewSizeAtRestPushesAndInMotionWaits() async throws {
        let art = try GlassBackdropTests.artFile()
        defer { try? FileManager.default.removeItem(at: art.deletingLastPathComponent()) }
        var rig = try await Rig(art: art)
        defer { rig.window.window.close() }
        rig.feed.refresh(newDocument: true)
        let backdrop = rig.window.backdrop

        backdrop.setFrameSize(NSSize(width: 400, height: 240))
        rig.frame()
        #expect(rig.scripts.all.count == 2, "the art's new size was not pushed")
        backdrop.setFrameSize(NSSize(width: 400, height: 240))
        rig.frame()
        #expect(rig.scripts.all.count == 2, "the same size pushed")

        let placement = SpringingPlacement(frame: rig.window.content.bounds)
        rig.window.content.addSubview(placement, positioned: .below, relativeTo: nil)
        placement.addSubview(backdrop)
        for step in 1...10 {
            backdrop.setFrameSize(NSSize(width: 400 + CGFloat(step * 4), height: 240))
            rig.frame()
        }
        #expect(rig.scripts.all.count == 2, "the art's sizes in a pane motion evaluated \(rig.scripts.all.count - 2) scripts")
    }

    /// A size at rest (a divider released, a split with no animation) pushes; the same size again, or one
    /// inside a pane motion, does not, and the motion's landing pushes the size it rests at.
    @Test func aNewSizeAtRestPushesAndOneInMotionWaitsForTheLanding() async throws {
        let art = try GlassBackdropTests.artFile()
        defer { try? FileManager.default.removeItem(at: art.deletingLastPathComponent()) }
        var rig = try await Rig(art: art)
        defer { rig.window.window.close() }
        rig.feed.refresh(newDocument: true)
        let page = rig.window.page

        page.frame.size.width = 160
        rig.feed.hostDidLayout()
        rig.frame()
        #expect(rig.scripts.all.count == 2, "a new size at rest was not pushed")
        rig.feed.hostDidLayout()
        rig.frame()
        #expect(rig.scripts.all.count == 2, "a layout at the same size pushed")

        let placement = SpringingPlacement(frame: rig.window.content.bounds)
        rig.window.content.addSubview(placement)
        placement.addSubview(page)
        for step in 1...10 {
            page.frame.size.width = 160 + CGFloat(step * 4)
            rig.feed.hostDidLayout()
            rig.frame()
        }
        #expect(rig.scripts.all.count == 2, "layouts in a pane motion evaluated \(rig.scripts.all.count - 2) scripts")

        placement.restOffset = .zero
        rig.feed.landed()
        rig.frame()
        #expect(rig.scripts.all.count == 3, "the landing did not push the size the page rests at")
        #expect(rig.feed.sent?.rect == rig.rectNow())
    }

    /// A page with no still asks for no frame when a spring, a move or a layout moves it; one that gets a
    /// still and then loses it (plain glass) drops it once.
    @Test func aPageWithNoStillSchedulesNoFrame() async throws {
        let art = try GlassBackdropTests.artFile()
        defer { try? FileManager.default.removeItem(at: art.deletingLastPathComponent()) }
        let glass = GlassChoice()
        var rig = try await Rig(art: art, mode: { glass.mode })
        defer { rig.window.window.close() }
        rig.feed.refresh(newDocument: true)
        rig.window.page.frame.size.width = 200
        rig.feed.layoutWillRest()
        rig.feed.hostDidLayout()
        rig.feed.placementSettled()
        rig.feed.landed()
        #expect(!rig.frames.hasLink, "a page with no still asked for a frame")
        #expect(rig.scripts.all.isEmpty)

        glass.mode = .lens
        rig.feed.refresh()
        #expect(rig.scripts.all.count == 1, "lens glass sent no still")
        glass.mode = .plain
        rig.feed.refresh()
        #expect(rig.scripts.all.count == 2, "plain glass did not drop the still")
        rig.feed.landed()
        rig.feed.placementSettled()
        rig.frame()
        #expect(rig.scripts.all.count == 2, "a page with no still was pushed again")
    }

    /// A hidden page: the feed stops hearing its backdrop, asks for no frame and pushes
    /// nothing, whatever moves meanwhile; the show pushes what changed once, on its next frame.
    @Test func aHiddenPageHasNoGlassObserverAndItsShowPushesOnce() async throws {
        let art = try GlassBackdropTests.artFile()
        defer { try? FileManager.default.removeItem(at: art.deletingLastPathComponent()) }
        var rig = try await Rig(art: art)
        defer { rig.window.window.close() }
        rig.feed.refresh(newDocument: true)
        #expect(rig.scripts.all.count == 1)
        #expect(rig.window.backdrop.glassFeeds.allObjects.count == 1)

        rig.feed.setPageShown(false)
        #expect(rig.window.backdrop.glassFeeds.allObjects.count == 0, "a hidden page's feed still observes its backdrop")
        rig.window.page.frame.origin.x = 60
        rig.window.backdrop.setFrameSize(NSSize(width: 360, height: 220))
        rig.feed.refresh()
        rig.feed.hostDidLayout()
        rig.feed.placementSettled()
        rig.feed.landed()
        for _ in 1...5 { rig.frame() }
        #expect(rig.scripts.all.count == 1, "a hidden page got \(rig.scripts.all.count - 1) glass pushes")
        #expect(rig.window.backdrop.glassFeeds.allObjects.count == 0)

        rig.feed.setPageShown(true)
        rig.frame()
        rig.frame()
        #expect(rig.scripts.all.count == 2, "the show pushed \(rig.scripts.all.count - 1) scripts, not one")
        #expect(rig.window.backdrop.glassFeeds.allObjects.count == 1, "the shown page's feed does not observe its backdrop again")
        #expect(rig.feed.sent?.rect == rig.rectNow(), "the show did not push the place the page has now")
    }

    /// A push the page held (a frozen page keeps only the newest glass push for its thaw):
    /// the next push carries every field and the image, so it can take the held one's place; after it, a
    /// push carries only what changed again.
    @Test func thePushAfterAHeldOneCarriesTheWholeState() async throws {
        let art = try GlassBackdropTests.artFile()
        defer { try? FileManager.default.removeItem(at: art.deletingLastPathComponent()) }
        var rig = try await Rig(art: art)
        defer { rig.window.window.close() }
        rig.feed.refresh(newDocument: true)
        #expect(rig.scripts.all.count == 1)
        #expect(rig.scripts.all.last?.contains("\"image\"") == true)

        rig.feed.pushWasHeld()
        rig.window.page.frame.origin.x = 40
        rig.feed.placementSettled()
        rig.frame()
        #expect(rig.scripts.all.count == 2)
        let whole = try #require(rig.scripts.all.last)
        for field in ["\"key\"", "\"image\"", "\"rect\"", "\"blur\"", "\"tint\""] {
            #expect(whole.contains(field), "the push after a held one left out \(field)")
        }

        rig.window.page.frame.origin.x = 50
        rig.feed.placementSettled()
        rig.frame()
        #expect(rig.scripts.all.count == 3)
        #expect(rig.scripts.all.last?.contains("\"image\"") == false, "a push after a run one resent the image")
    }
}

/// The glass mode a test switches.
@MainActor
private final class GlassChoice {
    var mode = GlassLensMode.plain
}

/// The live window resize a test switches (the feed's and the backdrop's `liveResize` seam).
@MainActor
private final class LiveResize {
    var isOn = false
}

/// A pane host on a layout spring (`RestingPlacement`): its content is in pane motion. On the render server its
/// frame is at rest from the spring's start (`PaneHostView.placeAtRest`).
private final class SpringingPlacement: NSView, RestingPlacement {
    var restOffset = CGVector(dx: 8, dy: 0)
    var onRenderServer = false
    var framePlacedAtRest: Bool { onRenderServer || !isOnLayoutSpring }
}
