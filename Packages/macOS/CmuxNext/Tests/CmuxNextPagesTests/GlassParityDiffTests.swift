#if DEBUG || CMUX_BENCH_HOOKS
import CoreGraphics
import Testing
@testable import CmuxNextPages

/// The Liquid Glass Parity playground's pixel diff (``GlassParityDiff``): the numbers its `measure` and
/// scripts/cmux-next/glass-parity-shots.py hold the web glass to.
@Suite struct GlassParityDiffTests {
    /// `width` by `height` RGBA pixels of one color.
    private func solid(_ r: UInt8, _ g: UInt8, _ b: UInt8, width: Int = 10, height: Int = 10) -> [UInt8] {
        (0..<(width * height)).flatMap { _ in [r, g, b, 255] }
    }

    @Test func identicalPicturesHaveNoError() throws {
        let diff = try #require(GlassParityDiff.compare(solid(10, 20, 30), solid(10, 20, 30), width: 10, height: 10, bytesPerRow: 40))
        #expect(diff == GlassParityDiff(mean: 0, p95: 0, p99: 0, max: 0, visible: 0, pixels: 100))
        #expect(diff.within(GlassParityDiff.hostTolerance))
    }

    @Test func aPixelsErrorIsItsWorstChannel() throws {
        let diff = try #require(GlassParityDiff.compare(solid(10, 20, 30), solid(13, 9, 31), width: 10, height: 10, bytesPerRow: 40))
        #expect(diff.mean == 11)
        #expect(diff.max == 11)
        #expect(diff.visible == 1)
        #expect(!diff.within(GlassParityDiff.hostTolerance))
    }

    @Test func percentilesFollowTheWorstPixels() throws {
        var b = solid(0, 0, 0)
        // Two of a hundred pixels are 50 off: the 99th percentile sees them, the 95th does not.
        b[0] = 50
        b[4] = 50
        let diff = try #require(GlassParityDiff.compare(solid(0, 0, 0), b, width: 10, height: 10, bytesPerRow: 40))
        #expect(diff.p95 == 0)
        #expect(diff.p99 == 50)
        #expect(diff.max == 50)
        #expect(diff.mean == 1)
    }

    @Test func excludedBoxesAreLeftOut() throws {
        var b = solid(0, 0, 0)
        for x in 0..<5 { b[x * 4] = 200 }
        let diff = try #require(GlassParityDiff.compare(solid(0, 0, 0), b, width: 10, height: 10, bytesPerRow: 40,
                                                       excluded: [CGRect(x: 0, y: 0, width: 5, height: 1)]))
        #expect(diff.max == 0)
        #expect(diff.pixels == 95)
    }

    @Test func aDriftPastTheToleranceFails() throws {
        // Every pixel 2 steps off: a mean of 2 is a drift a side-by-side shows on a large surface.
        let diff = try #require(GlassParityDiff.compare(solid(100, 100, 100), solid(102, 100, 100), width: 10, height: 10,
                                                       bytesPerRow: 40))
        #expect(!diff.within(GlassParityDiff.hostTolerance))
        let within = try #require(GlassParityDiff.compare(solid(100, 100, 100), solid(101, 100, 100), width: 10, height: 10,
                                                         bytesPerRow: 40))
        #expect(within.within(GlassParityDiff.hostTolerance))
    }

    @Test func tooSmallBuffersAreRefused() {
        #expect(GlassParityDiff.compare([0, 0, 0], [0, 0, 0], width: 10, height: 10, bytesPerRow: 40) == nil)
        #expect(GlassParityDiff.compare(solid(0, 0, 0), solid(0, 0, 0), width: 10, height: 10, bytesPerRow: 40,
                                        excluded: [CGRect(x: 0, y: 0, width: 10, height: 10)]) == nil)
    }
}
#endif
