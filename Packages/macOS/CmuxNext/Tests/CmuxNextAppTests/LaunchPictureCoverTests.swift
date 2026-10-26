import AppKit
import CmuxNextDesign
import CmuxNextDesignTokens
import CmuxNextWakeupsTestSupport
import Testing

/// p08-startup-060: the launch window's first frame is its picture from the last quit, and the live window is built
/// under it. The picture leaves region by region, each part at its region's first content, all of it by the bound;
/// no area of the window ever shows neither the picture nor its live views (a blank region). Fake regions: a host
/// with a sidebar area and a main pane area, each with a view held until its region's data lands.
@MainActor @Suite(.serialized) struct LaunchPictureCoverTests {
    @MainActor final class Launch {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let sidebar = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 300))
        let pane = NSView(frame: NSRect(x: 100, y: 0, width: 300, height: 280))
        let rig = MainDeadlineRig()
        let reveal: LaunchReveal
        var cover: LaunchPictureCover!

        init(produced: [LaunchRegion] = []) throws {
            reveal = LaunchReveal(clock: ManualClock(), deadline: .seconds(60))
            for view in [sidebar, pane] {
                view.wantsLayer = true
                host.addSubview(view)
            }
            reveal.hold(sidebar, until: .sidebar)
            reveal.hold(pane, until: .pane)
            for region in produced { reveal.markReady(region) }
            let image = try #require(Self.image(width: 400, height: 300))
            cover = LaunchPictureCover(image: image, over: host, parts: [
                .init(until: [.sidebar]) { [sidebar] in sidebar.frame },
                .init(until: [.tabs, .pane]) { [pane] in pane.frame },
            ], reveal: reveal, deadlines: rig.deadlines)
        }

        static func image(width: Int, height: Int) -> CGImage? {
            let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
            context?.fill(CGRect(x: 0, y: 0, width: width, height: height))
            return context?.makeImage()
        }

        /// The picture's parts still in the host.
        var pictureParts: Int { host.subviews.count - 2 }

        /// Whether `point` shows the picture or the live view under it: never neither.
        func drawsSomething(at point: CGPoint, live view: NSView) -> Bool {
            cover.covers(point) || view.alphaValue == 1
        }

        func noBlankRegion() -> Bool {
            drawsSomething(at: CGPoint(x: 50, y: 150), live: sidebar) && drawsSomething(at: CGPoint(x: 250, y: 150), live: pane)
                && (cover.covers(CGPoint(x: 250, y: 290)) || cover.isFinished)
        }
    }

    @Test func theFirstFrameIsThePictureOverEveryArea() throws {
        let launch = try Launch()
        #expect(launch.pictureParts == 3, "one part per area plus the rest of the window")
        #expect(launch.cover.covers(CGPoint(x: 50, y: 150)))
        #expect(launch.cover.covers(CGPoint(x: 250, y: 150)))
        #expect(launch.cover.covers(CGPoint(x: 250, y: 290)), "the title row above the pane")
        #expect(launch.host.subviews.last?.hitTest(CGPoint(x: 50, y: 150)) == nil, "the picture takes no click")
        #expect(launch.noBlankRegion())
    }

    @Test func eachPartLeavesAtItsRegionsFirstContent() throws {
        let launch = try Launch()
        launch.reveal.markReady(.sidebar)
        #expect(!launch.cover.covers(CGPoint(x: 50, y: 150)), "the sidebar's part left at its first rows")
        #expect(launch.sidebar.alphaValue == 1)
        #expect(launch.sidebar.layer?.animation(forKey: "opacity") == nil, "a covered region does not fade a second time")
        #expect(launch.cover.covers(CGPoint(x: 250, y: 150)), "the pane's part waits for the pane")
        #expect(launch.noBlankRegion())

        launch.reveal.markReady(.tabs)
        #expect(launch.cover.covers(CGPoint(x: 250, y: 150)), "tabs alone are not the pane's first content")
        #expect(launch.noBlankRegion())

        launch.reveal.markReady(.pane)
        #expect(launch.cover.isFinished)
        #expect(launch.pictureParts == 0, "the rest of the window left with the last part")
        #expect(!launch.rig.hasArmedWake, "the bound goes with the picture")
        #expect(launch.noBlankRegion())
    }

    @Test func theBoundTakesThePictureDownWithNoContent() throws {
        let launch = try Launch()
        launch.rig.advance(by: LaunchPictureCover.bound - .milliseconds(1))
        launch.rig.frame()
        #expect(!launch.cover.isFinished, "the picture stays while its regions have no content, up to the bound")
        launch.rig.fireAndRun()
        #expect(launch.rig.elapsed >= 2, "the bound is 2 s")
        #expect(launch.cover.isFinished)
        #expect(launch.pictureParts == 0)
        #expect(launch.sidebar.alphaValue == 1 && launch.pane.alphaValue == 1, "every region shows its live views")
        #expect(!launch.reveal.isProduced(.pane), "the bound is not first content")
        #expect(launch.noBlankRegion())
    }

    @Test func aRegionThatDrewBeforeTheCoverGetsNoPart() throws {
        let launch = try Launch(produced: [.sidebar])
        #expect(!launch.cover.covers(CGPoint(x: 50, y: 150)))
        #expect(launch.cover.covers(CGPoint(x: 250, y: 150)))
        #expect(launch.pictureParts == 2)
    }

    @Test func aResizeDropsThePictureAtOnce() throws {
        let launch = try Launch()
        launch.host.setFrameSize(NSSize(width: 500, height: 300))
        #expect(!launch.cover.layout(), "a picture of another size would show the window stretched")
        #expect(launch.cover.isFinished)
        #expect(launch.pictureParts == 0)
        #expect(launch.reveal.isRevealed, "every region shows its live views")
    }
}
