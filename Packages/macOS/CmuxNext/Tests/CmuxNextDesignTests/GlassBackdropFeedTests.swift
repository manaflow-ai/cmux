import AppKit
@testable import CmuxNextDesign
import Foundation
import Testing
import CmuxNextWakeups

/// The glass feed evaluates no script per frame of a motion (chrome-parity p03-rendering-037): a page's
/// place in its window is pushed when it is final, at a spring's start and landing, at a live window
/// resize's end, and for a new size at rest. Frame and bounds changes of the page or its ancestors push
/// nothing by themselves, and the feed observes no notification.
@MainActor @Suite struct GlassBackdropFeedTests {
    /// A feed over a shown window's page, with its own frames.
    @MainActor
    private struct Rig {
        let window: GlassFeedWindow
        let feed: GlassBackdropFeed
        let frames: FrameScheduler
        let scripts: Scripts
        private var timestamp = 0.0

        init(art: URL, mode: @escaping @MainActor () -> GlassLensMode = { .lens }) async throws {
            let stills = GlassBackdropImages(maxPixelSize: 64)
            let window = try await GlassFeedWindow(art: art, store: BackdropImageStore(maxPixelSize: 64), stills: stills, own: .visible)
            let frames = FrameScheduler.testing(mediaTime: { 500 }) { _ in GlassFeedLink() }
            let scripts = Scripts()
            self.window = window
            self.frames = frames
            self.scripts = scripts
            feed = GlassBackdropFeed(host: window.page, zoom: { 1 }, images: stills, mode: mode,
                                     scheduler: { _ in frames }) { scripts.all.append($0) }
        }

        /// One display frame.
        mutating func frame() {
            timestamp += 1
            frames.frameDidFire(timestamp: timestamp, refreshInterval: 1.0 / 60)
        }
    }

    @Test func aPageMovingEveryFrameIsPushedOnlyWhenItLands() async throws {
        let art = try GlassBackdropTests.artFile()
        defer { try? FileManager.default.removeItem(at: art.deletingLastPathComponent()) }
        var rig = try await Rig(art: art)
        defer { rig.window.window.close() }
        rig.feed.refresh(newDocument: true)
        #expect(rig.scripts.all.count == 1, "the new document got no still")

        for step in 1...20 {
            rig.window.page.frame.origin.x = 20 + CGFloat(step) // the page moves on a CPU spring
            rig.window.content.frame.origin.y = CGFloat(step) // and its ancestor with it
            rig.frame()
        }
        #expect(rig.scripts.all.count == 1, "frames of the motion evaluated \(rig.scripts.all.count - 1) scripts")

        rig.feed.landed()
        rig.frame()
        #expect(rig.scripts.all.count == 2, "the landing pushed no place")
        #expect(rig.scripts.all.last?.contains("\"rect\"") == true)
        #expect(rig.scripts.all.last?.contains("\"image\"") == false, "a move resent the image")
    }

    /// A render-server spring places the page at rest in the key's turn (`PaneHostView.placeAtRest`): the push
    /// at its start carries the rest, and the landing sends nothing. A CPU spring pushes once at the start and
    /// once at the landing. Either way at most two scripts per spring.
    @Test func aSpringEvaluatesAtMostTwoScripts() async throws {
        let art = try GlassBackdropTests.artFile()
        defer { try? FileManager.default.removeItem(at: art.deletingLastPathComponent()) }
        var rig = try await Rig(art: art)
        defer { rig.window.window.close() }
        rig.feed.refresh(newDocument: true)
        let page = rig.window.page

        // On the render server: announced, then the frame is set once, to rest.
        rig.feed.layoutWillRest()
        page.frame = NSRect(x: 160, y: 20, width: 140, height: 80)
        for _ in 1...10 { rig.frame() }
        rig.feed.landed()
        rig.frame()
        #expect(rig.scripts.all.count == 2, "a render-server spring evaluated \(rig.scripts.all.count - 1) scripts")

        // On the CPU: the start's push sees the first frame's place, the landing's the rest.
        rig.feed.layoutWillRest()
        page.frame.origin.x = 150
        rig.frame()
        for step in 1...10 {
            page.frame.origin.x = 150 - CGFloat(step * 10)
            rig.frame()
        }
        rig.feed.landed()
        rig.frame()
        #expect(rig.scripts.all.count == 4, "a CPU spring evaluated \(rig.scripts.all.count - 2) scripts")
    }

    @Test func aWindowResizePushesOnceAtItsEnd() async throws {
        let art = try GlassBackdropTests.artFile()
        defer { try? FileManager.default.removeItem(at: art.deletingLastPathComponent()) }
        var rig = try await Rig(art: art)
        defer { rig.window.window.close() }
        rig.feed.refresh(newDocument: true)

        for step in 1...20 {
            rig.window.content.frame.size.width = 320 + CGFloat(step * 4)
            rig.window.page.frame.size.width = 120 + CGFloat(step * 2)
            rig.frame()
        }
        #expect(rig.scripts.all.count == 1, "the resize's frames evaluated \(rig.scripts.all.count - 1) scripts")

        rig.window.backdrop.viewDidEndLiveResize() // AppKit tells every view in the window
        rig.window.page.viewDidEndLiveResize()
        rig.frame()
        rig.frame()
        #expect(rig.scripts.all.count == 2, "the resize's end pushed \(rig.scripts.all.count - 1) scripts, not one")
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
    }

    /// A page with no still asks for no frame when a spring or a layout moves it; one that gets a still
    /// and then loses it (plain glass) drops it once.
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
        rig.frame()
        #expect(rig.scripts.all.count == 2, "a page with no still was pushed again")
    }
}

/// The glass mode a test switches.
@MainActor
private final class GlassChoice {
    var mode = GlassLensMode.plain
}

/// A pane host on a layout spring (`RestingPlacement`): its content is in pane motion.
private final class SpringingPlacement: NSView, RestingPlacement {
    var restOffset = CGVector(dx: 8, dy: 0)
}
