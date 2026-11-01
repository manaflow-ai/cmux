import AppKit
import CmuxNextDesignTokens
@testable import CmuxNextApp
import Foundation
import QuartzCore
import Testing

/// One captured hint sequence of ``CmdHintPixelTests``: every frame whole, judged against the two
/// goldens (chips gone, chips shown) and the declared fades.
@available(macOS 14.4, *)
@MainActor
struct HintRun {
    let fixture: CmdHintPixelTests.Fixture
    let name: String
    let scale: Int
    let dark: Bool

    /// One frame read as a blend of the goldens: its opacity (least squares over the pixels the
    /// goldens differ in), and the pixels more than the tolerance from that blend.
    struct Reading {
        let time: Double
        let opacity: Double
        let misses: Int
        let worst: Int
    }

    /// Holds (`hold`), waits for the hold delay and the fade in, releases (`release`), waits for the
    /// fade out; judges every frame.
    func holdAndRelease(animated: Bool, hold: () -> Void, release: () -> Void) async throws -> [String] {
        let fadeIn = try DeclaredFade.declared(.fadeIn), fadeOut = try DeclaredFade.declared(.fadeOut)
        let delay = Double(ShortcutHintModifierPolicy.intentionalHoldDelay.components.attoseconds) / 1e18
            + Double(ShortcutHintModifierPolicy.intentionalHoldDelay.components.seconds)
        let stream = WindowFrameStream(rowY: 0, columnX: 0, keepsImages: true)
        try await stream.start(window: fixture.window)
        try await Task.sleep(for: .milliseconds(300))
        let down = CACurrentMediaTime()
        hold()
        try await Task.sleep(for: .milliseconds(Int((delay + fadeIn.duration) * 1000) + 300))
        let shownImage = stream.lastImage
        let up = CACurrentMediaTime()
        release()
        try await Task.sleep(for: .milliseconds(Int(fadeOut.duration * 1000) + 300))
        await stream.stop()
        let frames = stream.capturedImages
        guard let first = frames.first?.image, let shown = shownImage else {
            throw AnimationPixelRun.Failure(description: "\(name): ScreenCaptureKit gave no frame (\(stream.idleFrames) idle, stop error \(stream.stopError ?? "none"))")
        }
        var failures: [String] = []
        let off = try golden("off", captured: Self.image(first), failures: &failures)
        let on = try golden("on", captured: Self.image(shown), failures: &failures)
        guard let off, let on else { return failures }
        let period = fixture.display.refreshPeriod
        let readings = frames.map { read($0.image, time: $0.time, off: off, on: on) }
        for reading in readings where reading.misses > 0 {
            failures.append("t=\(AnimationPixelRun.ms(reading.time - down)) ms: \(reading.misses) pixels are up to \(reading.worst)/255 from the "
                + "golden blend at opacity \(String(format: "%.3f", reading.opacity)) (tolerance \(CmdHintPixelTests.tolerance)/255)")
        }
        // In: hidden until the hold delay, then the fadeIn curve from one origin; out: the fadeOut curve from the release.
        failures += judgeFade(readings.filter { $0.time < up + period }, fade: fadeIn, start: down + delay, rising: true,
                              animated: animated, period: period, label: "in")
        failures += judgeFade(readings.filter { $0.time >= up }, fade: fadeOut, start: up, rising: false,
                              animated: animated, period: period, label: "out")
        print("ANIMATION-PIXEL \(name): \(frames.count) frames, \(stream.idleFrames) idle; opacities "
            + readings.map { "\(AnimationPixelRun.ms($0.time - down)):\(String(format: "%.2f", $0.opacity))" }.joined(separator: " "))
        for failure in failures.prefix(40) { print("ANIMATION-PIXEL \(name): FAIL \(failure)") }
        return failures
    }

    /// Holds, clicks before the hold delay ends, holds on past it, releases: every frame must be
    /// the chips-gone golden exactly.
    func cmdClick(hold: () -> Void, click: () -> Void, release: () -> Void) async throws -> [String] {
        let stream = WindowFrameStream(rowY: 0, columnX: 0, keepsImages: true)
        try await stream.start(window: fixture.window)
        try await Task.sleep(for: .milliseconds(300))
        let down = CACurrentMediaTime()
        hold()
        try await Task.sleep(for: .milliseconds(80))
        click()
        try await Task.sleep(for: .milliseconds(700))
        release()
        try await Task.sleep(for: .milliseconds(300))
        await stream.stop()
        let frames = stream.capturedImages
        guard let first = frames.first?.image else { throw AnimationPixelRun.Failure(description: "\(name): ScreenCaptureKit gave no frame") }
        var failures: [String] = []
        guard let off = try golden("off", captured: Self.image(first), failures: &failures) else { return failures }
        for frame in frames {
            let (misses, worst) = Self.compare(frame.image, off)
            if misses > 0 {
                failures.append("t=\(AnimationPixelRun.ms(frame.time - down)) ms: a chip flickered in on a plain Cmd-click "
                    + "(\(misses) pixels up to \(worst)/255 off the chips-gone golden)")
            }
        }
        print("ANIMATION-PIXEL \(name): \(frames.count) frames, \(failures.count) failures")
        for failure in failures.prefix(40) { print("ANIMATION-PIXEL \(name): FAIL \(failure)") }
        return failures
    }

    // MARK: Judging

    private func golden(_ state: String, captured: HintGoldens.Image, failures: inout [String]) throws -> HintGoldens.Image? {
        let file = HintGoldens.name(state, dark: dark, scale: scale)
        guard let golden = HintGoldens.load(file) else {
            try HintGoldens.capture(captured, as: file)
            failures.append("no golden \(file): the captured image is in artifacts/animation-pixel-goldens/ for a golden commit (own commit, reason, reviewer receipt)")
            return nil
        }
        guard golden.width == captured.width, golden.height == captured.height else {
            failures.append("golden \(file) is \(golden.width)x\(golden.height), the window is \(captured.width)x\(captured.height)")
            return nil
        }
        let (misses, worst) = Self.compare(captured, golden)
        if misses > 0 {
            try HintGoldens.capture(captured, as: file)
            failures.append("the \(state) state differs from golden \(file) in \(misses) pixels, up to \(worst)/255 (captured image in artifacts/animation-pixel-goldens/)")
        }
        return golden
    }

    static func image(_ image: WindowFrameStream.Image) -> HintGoldens.Image {
        HintGoldens.Image(width: image.width, height: image.height, pixels: image.pixels)
    }

    static func channels(_ pixel: UInt32) -> [Int] {
        [Int(pixel & 0xFF), Int((pixel >> 8) & 0xFF), Int((pixel >> 16) & 0xFF), Int((pixel >> 24) & 0xFF)]
    }

    /// Pixels more than the tolerance apart, and the largest channel difference.
    static func compare(_ image: WindowFrameStream.Image, _ golden: HintGoldens.Image) -> (Int, Int) {
        compare(Self.image(image), golden)
    }

    static func compare(_ image: HintGoldens.Image, _ golden: HintGoldens.Image) -> (Int, Int) {
        guard image.width == golden.width, image.height == golden.height else { return (image.pixels.count, 255) }
        var misses = 0, worst = 0
        for (a, b) in zip(image.pixels, golden.pixels) where a != b {
            let difference = zip(channels(a), channels(b)).map { abs($0 - $1) }.max() ?? 0
            worst = max(worst, difference)
            if difference > CmdHintPixelTests.tolerance { misses += 1 }
        }
        return (misses, worst)
    }

    private func read(_ image: WindowFrameStream.Image, time: Double, off: HintGoldens.Image, on: HintGoldens.Image) -> Reading {
        guard image.width == off.width, image.height == off.height else { return Reading(time: time, opacity: .nan, misses: image.pixels.count, worst: 255) }
        var numerator = 0.0, denominator = 0.0
        for index in image.pixels.indices where off.pixels[index] != on.pixels[index] {
            let shown = Self.channels(image.pixels[index]), a = Self.channels(off.pixels[index]), b = Self.channels(on.pixels[index])
            for channel in 0..<4 where abs(b[channel] - a[channel]) >= 8 {
                let span = Double(b[channel] - a[channel])
                numerator += Double(shown[channel] - a[channel]) * span
                denominator += span * span
            }
        }
        let opacity = denominator > 0 ? min(max(numerator / denominator, 0), 1) : 0
        var misses = 0, worst = 0
        for index in image.pixels.indices {
            let shown = Self.channels(image.pixels[index]), a = Self.channels(off.pixels[index]), b = Self.channels(on.pixels[index])
            var difference = 0
            for channel in 0..<4 {
                let low = Double(a[channel]), high = Double(b[channel])
                let blend: Double = low + (high - low) * opacity
                let apart = Int(abs(Double(shown[channel]) - blend).rounded())
                difference = max(difference, apart)
            }
            worst = max(worst, difference)
            if difference > CmdHintPixelTests.tolerance { misses += 1 }
        }
        return Reading(time: time, opacity: opacity, misses: misses, worst: worst)
    }

    /// The opacities of `readings` against `fade` started at `start` (one origin fitted within a
    /// few frames after it, the display latency): each within the fade tolerance, never stepping
    /// back, ending at the end state. Animations off: only 0 or 1, and the change in one frame.
    private func judgeFade(_ readings: [Reading], fade: DeclaredFade, start: Double, rising: Bool, animated: Bool,
                           period: Double, label: String) -> [String] {
        var failures: [String] = []
        let target: (Double) -> Double = { elapsed in rising ? fade.progress(at: elapsed) : 1 - fade.progress(at: elapsed) }
        guard let last = readings.last else { return ["\(label): no frame"] }
        if abs(last.opacity - (rising ? 1 : 0)) > CmdHintPixelTests.fadeTolerance {
            failures.append("\(label): the last frame's opacity is \(String(format: "%.3f", last.opacity)), not \(rising ? 1 : 0)")
        }
        if !animated {
            for reading in readings where reading.opacity > CmdHintPixelTests.fadeTolerance && reading.opacity < 1 - CmdHintPixelTests.fadeTolerance {
                failures.append("\(label): opacity \(String(format: "%.3f", reading.opacity)) at t=\(AnimationPixelRun.ms(reading.time - start)) ms with animations off")
            }
            return failures
        }
        var best = (origin: start, error: Double.infinity), origin = start
        while origin <= start + 5 * period {
            let error = readings.map { abs($0.opacity - target($0.time - origin)) }.max() ?? .infinity
            if error < best.error { best = (origin: origin, error: error) }
            origin += 0.0001
        }
        for reading in readings where abs(reading.opacity - target(reading.time - best.origin)) > CmdHintPixelTests.fadeTolerance {
            failures.append("\(label): opacity \(String(format: "%.3f", reading.opacity)) at t=\(AnimationPixelRun.ms(reading.time - best.origin)) ms, "
                + "the \(fade) fade says \(String(format: "%.3f", target(reading.time - best.origin)))")
        }
        for (a, b) in zip(readings, readings.dropFirst()) where (rising ? b.opacity < a.opacity : b.opacity > a.opacity) && abs(b.opacity - a.opacity) > CmdHintPixelTests.fadeTolerance {
            failures.append("\(label): the opacity stepped back from \(String(format: "%.3f", a.opacity)) to \(String(format: "%.3f", b.opacity))")
        }
        let moving = readings.filter { $0.opacity > CmdHintPixelTests.fadeTolerance && $0.opacity < 1 - CmdHintPixelTests.fadeTolerance }
        let expected = Int((fade.duration / period).rounded(.down)) - 2
        if moving.count < expected {
            failures.append("\(label): \(moving.count) frames between hidden and shown, the \(fade) fade has \(expected + 2) refreshes (dropped frames)")
        }
        return failures
    }
}
