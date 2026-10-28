import AppKit
import AVFoundation
@testable import CmuxNextDesign
import QuartzCore
import Testing

/// `debug.layers` `frame_sources`: the frame sources no FrameScheduler sees.
@MainActor
struct RenderStatsFrameSourcesTests {
    final class StarFieldView: NSView {}

    @Test func everyInfiniteLoopCountsUnderItsNearestViewShownOrHidden() throws {
        let view = StarFieldView(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        view.wantsLayer = true
        let backing = try #require(view.layer)
        let star = CALayer()
        let hiddenStar = CALayer()
        hiddenStar.isHidden = true
        backing.addSublayer(star)
        backing.addSublayer(hiddenStar)
        let loop = CABasicAnimation(keyPath: "opacity")
        loop.repeatCount = .infinity
        let forever = CABasicAnimation(keyPath: "position")
        forever.repeatDuration = .infinity
        star.add(loop, forKey: "twinkle")
        star.add(CABasicAnimation(keyPath: "bounds"), forKey: "once")
        hiddenStar.add(forever, forKey: "drift")
        let loose = CALayer()
        loose.add(loop, forKey: "spin")

        let counts = RenderStats.loopingAnimations(under: [backing, loose])

        #expect(counts == [String(describing: StarFieldView.self): 2, String(describing: CALayer.self): 1])
    }

    @Test func aPausedVideoLayerIsNoFrameSource() {
        let root = CALayer()
        root.addSublayer(AVPlayerLayer(player: AVPlayer()))
        #expect(RenderStats.playingVideoLayers(under: [root]).isEmpty)
    }
}
