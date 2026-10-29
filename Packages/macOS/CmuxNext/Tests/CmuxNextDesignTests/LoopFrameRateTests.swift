import AppKit
@testable import CmuxNextDesign
import CmuxNextDesignTokens
import CmuxNextWakeups
import QuartzCore
import Testing

/// Looping indicators ask the render server for only the frames they need while
/// `DesignSettings.loopsFollowFrameRate` (feature `frameRateClasses`), and never change
/// their timing for it.
@MainActor @Suite(.serialized) struct LoopFrameRateTests {
    private func loops() throws -> [(String, CAAnimation)] {
        let gate = Motion.indicators
        return [
            ("spin", try #require(gate.spinAnimation())),
            ("sweep", try #require(gate.sweepAnimation(segment: 10, travel: 100))),
            ("breath", try #require(gate.breathAnimation(low: 0.4))),
            ("pulse", try #require(gate.pulseAnimation(low: 0.3))),
        ]
    }

    @Test func onLoopsAskFor30HzWithTheSameTiming() throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil; DesignSettings.shared.loopsFollowFrameRate = false }
        let before = try loops().map { ($0.0, $0.1.duration, $0.1.repeatCount) }
        DesignSettings.shared.loopsFollowFrameRate = true
        let after = try loops()
        for ((name, duration, repeats), (_, loop)) in zip(before, after) {
            #expect(loop.preferredFrameRateRange.maximum == 30, "\(name) asks for \(loop.preferredFrameRateRange.maximum) Hz")
            #expect(loop.duration == duration && loop.repeatCount == repeats, "\(name)'s timing changed")
        }
        let spinner = try #require(Motion.indicators.period(.spinner))
        let steps = try #require(Motion.indicators.stepAnimation(steps: 8))
        #expect(steps.preferredFrameRateRange.minimum == FrameRate.stepping(8, every: spinner).hertz)
        #expect(steps.preferredFrameRateRange.maximum <= 30)
    }

    /// The decision is the policy's: an injected policy paces a loop, whatever the shared settings say.
    @Test func anInjectedPolicyPacesTheSweep() throws {
        var policy = MotionPolicy(speed: .fast, reduceMotion: false, pacesLoops: true)
        let paced = try #require(Motion.indicators.sweepAnimation(segment: 10, travel: 100, policy: policy))
        #expect(paced.preferredFrameRateRange.maximum == 30)
        policy.pacesLoops = false
        let plain = try #require(Motion.indicators.sweepAnimation(segment: 10, travel: 100, policy: policy))
        #expect(plain.preferredFrameRateRange.maximum == CAFrameRateRange.default.maximum)
        #expect(plain.duration == paced.duration)
    }

    /// The night sky's twinkle and Z rise (a group: its parts ask too) ask for 30 Hz when paced and
    /// keep the default range when not, with the same duration, offset and repeat count either way.
    @Test func nightSkyLoopsAskFor30HzWithTheSameTiming() throws {
        defer { DesignSettings.shared.loopsFollowFrameRate = false }
        func skyLoops() throws -> [(String, CAAnimation)] {
            // The sky runs its loops only while it shows (LoopVisibility): in a window that reads visible.
            let host = LoopTestWindow()
            let sky = NightSkyView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            host.window.contentView = sky
            sky.layout()
            let layers = try #require(sky.layer?.sublayers)
            return try layers.map { layer in
                let key = layer is CATextLayer ? "rise" : "twinkle"
                let loop = try #require(layer.animation(forKey: key), "\(key) missing")
                return (key, loop)
            }
        }
        DesignSettings.shared.loopsFollowFrameRate = false
        let plain = try skyLoops()
        DesignSettings.shared.loopsFollowFrameRate = true
        let paced = try skyLoops()
        #expect(plain.count == 93 && paced.count == 93, "90 stars and 3 Zs")
        #expect(paced.contains { $0.0 == "rise" } && paced.contains { $0.0 == "twinkle" })
        for ((name, before), (_, after)) in zip(plain, paced) {
            #expect(before.preferredFrameRateRange.maximum == CAFrameRateRange.default.maximum, "\(name) asked for a rate")
            #expect(after.preferredFrameRateRange.maximum == 30, "\(name) asks for \(after.preferredFrameRateRange.maximum) Hz")
            #expect(after.duration == before.duration && after.timeOffset == before.timeOffset
                && after.repeatCount == before.repeatCount && after.autoreverses == before.autoreverses, "\(name)'s timing changed")
            for part in (after as? CAAnimationGroup)?.animations ?? [] {
                #expect(part.preferredFrameRateRange.maximum == 30, "a part of \(name) keeps the full rate")
            }
        }
    }

    /// The frames loop steps at twice its step rate (capped at 30), with the same timing.
    @Test func framesLoopStepsAtTwiceItsStepRate() throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil; DesignSettings.shared.loopsFollowFrameRate = false }
        let context = try #require(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        let frames = Array(repeating: image, count: 8)
        DesignSettings.shared.loopsFollowFrameRate = false
        let plain = try #require(Motion.indicators.framesAnimation(frames))
        DesignSettings.shared.loopsFollowFrameRate = true
        let paced = try #require(Motion.indicators.framesAnimation(frames))
        let period = try #require(Motion.indicators.period(.spinner))
        #expect(plain.preferredFrameRateRange.maximum == CAFrameRateRange.default.maximum)
        #expect(paced.preferredFrameRateRange.minimum == Float(min((16 / period).rounded(.up), 30)))
        #expect(paced.preferredFrameRateRange.maximum == 30)
        #expect(paced.duration == plain.duration && paced.repeatCount == plain.repeatCount)
    }

    @Test func offLoopsKeepTheDefaultRange() throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        DesignSettings.shared.loopsFollowFrameRate = false
        for (name, loop) in try loops() {
            #expect(loop.preferredFrameRateRange.maximum == CAFrameRateRange.default.maximum, "\(name) asked for a rate")
        }
    }
}
