import AppKit
import Testing
@testable import CmuxNextAgentPane

/// A fast guard for Leo's New Tab and split first-frame flicker reports. The frame shown while a
/// page settles must have the same pixels as the frame the page keeps after it settles.
@MainActor
struct NewTabPerceivedFlickerTests {
    private static let newTabSize = CGSize(width: 320, height: 240)
    private static let splitSize = CGSize(width: 160, height: 240)

    @Test func newTabFirstFrameMatchesSettledFramePixels() throws {
        let frames = AgentPaneNewTabFrame()
        let firstFrame = try Self.sample(size: Self.newTabSize)
        frames.store(firstFrame, size: Self.newTabSize, appearance: .darkAqua, generation: frames.generation)
        let first = try #require(frames.image(size: Self.newTabSize, appearance: .darkAqua))
        let settled = try Self.sample(size: Self.newTabSize)
        #expect(Self.pixelDifference(first, settled) == 0)
        let repainted = try Self.sample(size: Self.newTabSize, accentOrigin: CGPoint(x: 12, y: 8))
        #expect(Self.pixelDifference(first, repainted) > 0, "the detector sees a shifted first-frame repaint")
    }

    @Test func splitFirstFrameMatchesSettledFramePixelsAtItsTargetSize() throws {
        let frames = AgentPaneNewTabFrame()
        let firstFrame = try Self.sample(size: Self.splitSize)
        frames.store(firstFrame, size: Self.splitSize, appearance: .darkAqua, generation: frames.generation)
        let first = try #require(frames.image(size: Self.splitSize, appearance: .darkAqua))
        let settled = try Self.sample(size: Self.splitSize)
        #expect(Self.pixelDifference(first, settled) == 0)
        let repainted = try Self.sample(size: Self.splitSize, accentOrigin: CGPoint(x: 12, y: 8))
        #expect(Self.pixelDifference(first, repainted) > 0, "the detector sees a shifted split first-frame repaint")
    }

    private static func sample(size: CGSize, accentOrigin: CGPoint = CGPoint(x: 8, y: 8)) throws -> NSImage {
        let width = Int(size.width), height = Int(size.height)
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.08, green: 0.1, blue: 0.14, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0.3, green: 0.7, blue: 0.95, alpha: 1))
        context.fill(CGRect(x: accentOrigin.x, y: accentOrigin.y, width: min(32, width), height: min(32, height)))
        return NSImage(cgImage: try #require(context.makeImage()), size: size)
    }

    /// Count pixels whose RGBA values differ. This stays deliberately small so the check is fast in
    /// every package test run and catches a real first-frame repaint rather than timing alone.
    private static func pixelDifference(_ lhs: NSImage, _ rhs: NSImage) -> Int {
        guard let left = lhs.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let right = rhs.cgImage(forProposedRect: nil, context: nil, hints: nil),
              left.width == right.width, left.height == right.height else { return Int.max }
        let l = NSBitmapImageRep(cgImage: left), r = NSBitmapImageRep(cgImage: right)
        var different = 0
        for y in 0..<left.height {
            for x in 0..<left.width {
                guard let lc = l.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      let rc = r.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      abs(lc.redComponent - rc.redComponent) < 0.0001,
                      abs(lc.greenComponent - rc.greenComponent) < 0.0001,
                      abs(lc.blueComponent - rc.blueComponent) < 0.0001,
                      abs(lc.alphaComponent - rc.alphaComponent) < 0.0001 else {
                    different += 1
                    continue
                }
            }
        }
        return different
    }
}
