import AppKit
import CmuxHomeRender
import Foundation
import Testing
@testable import MessagesLabHome

/// What one sent-bubble draw pays for its themed gradient (#28259): the gradient lookup or creation PLUS the CGContext
/// draw into an offscreen bitmap, the way `PartRenderer.fillBubble` draws it (clip to a 480x120 px bubble, a linear
/// gradient over the window span, both draws-before/after options). Arms, nanoseconds per bubble:
/// - palette: `Fixture.outgoingGradient` in a palette scope, as every draw reads it (the app's path).
/// - newEach: a new CGGradient for every draw (`Colors.outgoingGradient` each time; #28259's first head).
/// - paletteFresh / newFresh: the same two, each into a fresh context (a row bitmap's first bubble; the context is made
///   outside the timing).
/// A measurement, not a gate: quote the `outgoing-gradient-draw-cost` line. A claim uses the worst arm.
@MainActor @Suite(.serialized) struct OutgoingGradientDrawCostBench {
    private static let runs = 5_000
    private static let freshRuns = 500
    private static let bubble = CGRect(x: 0, y: 0, width: 480, height: 120)

    private static func context() -> CGContext? {
        let width: Int = Int(bubble.width)
        let height: Int = Int(bubble.height)
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let info: UInt32 = CGImageAlphaInfo.premultipliedLast.rawValue
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                         bitmapInfo: info)
    }

    /// One bubble fill, as `fillBubble` draws it, at window y 300 pt.
    private static func draw(_ gradient: CGGradient?, in ctx: CGContext) {
        let windowY: CGFloat = 300
        let start = CGPoint(x: 0, y: -windowY)
        let end = CGPoint(x: 0, y: Fixture.gradientHeight - windowY)
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: bubble, cornerWidth: 30, cornerHeight: 30, transform: nil))
        ctx.clip()
        if let gradient {
            ctx.drawLinearGradient(gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        ctx.restoreGState()
    }

    private static func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

    /// `count` timed draws of `gradient()` into `target()` (a fresh context per draw when it makes one).
    private static func samples(_ count: Int, _ target: () -> CGContext?, _ gradient: () -> CGGradient?) -> [Double] {
        var out = [Double](); out.reserveCapacity(count)
        for _ in 0..<count {
            guard let ctx = target() else { continue }
            let t0 = now()
            draw(gradient(), in: ctx)
            out.append(Double(now() - t0))
        }
        return out
    }

    private static func line(_ name: String, _ samples: [Double]) -> String {
        let sorted = samples.sorted()
        func q(_ p: Double) -> Int {
            let count: Int = sorted.count
            let slot: Int = min(count - 1, Int(Double(count) * p))
            return Int(sorted[checked: slot] ?? 0)
        }
        let maximum: Int = Int(sorted.last ?? 0)
        return "\(name) p50=\(q(0.5))ns p95=\(q(0.95))ns p99=\(q(0.99))ns max=\(maximum)ns"
    }

    @Test func gradientPlusDrawPerBubble() throws {
        let theme = PaletteGradientReuseTests.themed()
        let box = PaletteScope.box(for: theme)
        let colors = theme.active
        let shared = try #require(Self.context())
        let palette: () -> CGGradient? = { PaletteScope.with(box) { Fixture.outgoingGradient } }
        let newEach: () -> CGGradient? = { colors.outgoingGradient }
        _ = Self.samples(200, { shared }, palette)  // warm
        let paletteArm = Self.samples(Self.runs, { shared }, palette)
        let newArm = Self.samples(Self.runs, { shared }, newEach)
        let paletteFresh = Self.samples(Self.freshRuns, Self.context, palette)
        let newFresh = Self.samples(Self.freshRuns, Self.context, newEach)
        #expect(paletteArm.count == Self.runs && newArm.count == Self.runs)
        let lines = [Self.line("palette", paletteArm), Self.line("newEach", newArm),
                     Self.line("paletteFresh", paletteFresh), Self.line("newFresh", newFresh)]
        print("outgoing-gradient-draw-cost runs=\(Self.runs) fresh=\(Self.freshRuns) bubble=480x120px " + lines.joined(separator: " | "))
    }
}
