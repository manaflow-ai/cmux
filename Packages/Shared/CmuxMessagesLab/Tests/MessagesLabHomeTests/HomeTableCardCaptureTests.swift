import AppKit
@testable import CmuxHomeCore
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import MessagesLabHome

/// The PR's before/after of Chief chat message 137: the real Home view over the mock owner, the
/// reply posted by the Chief, drawn once with Rich tables off (the table in the bubble) and once
/// on (the plan card), side by side in `.build/home-table-cards.png` (a fleet step returns it with
/// `--artifact`). It checks only that both drew; the picture is for people. In the serialized
/// HomeTableCardTests suite: it flips the process-wide Rich tables switch.
extension HomeTableCardTests {
    static let captureWidth: CGFloat = 760

    @MainActor func render(richTables: Bool) async throws -> CGImage? {
        HomeTableRowProvider.isOn = richTables
        defer { HomeTableRowProvider.isOn = true }
        let rig = try await HomeChatRig(history: 0, width: Self.captureWidth)
        defer { rig.stop() }
        _ = await rig.post(HomeTableCardTests.reply, key: IdempotencyKey("run_capture_137"))
        // Row bitmaps draw off main: give them a few frames.
        for _ in 0..<12 {
            rig.frame()
            try await Task.sleep(for: .milliseconds(150))
        }
        guard let layer = rig.view.layer else { return nil }
        let scale: CGFloat = 2
        let size = rig.view.bounds.size
        guard let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        // The view's layers are y-down (a flipped NSView); a bitmap context is y-up.
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        layer.render(in: ctx)
        return ctx.makeImage()
    }

    @MainActor @Test func beforeAndAfterOfMessage137() async throws {
        let before = try await render(richTables: false)
        let after = try await render(richTables: true)
        let b = try #require(before)
        let a = try #require(after)
        let gap = 40
        guard let ctx = CGContext(data: nil, width: b.width + gap + a.width, height: max(b.height, a.height), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { Issue.record("no context"); return }
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        ctx.draw(b, in: CGRect(x: 0, y: 0, width: b.width, height: b.height))
        ctx.draw(a, in: CGRect(x: b.width + gap, y: 0, width: a.width, height: a.height))
        let image = try #require(ctx.makeImage())
        // The package directory: this file is Tests/MessagesLabHomeTests/<name>.swift.
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let out = package.appendingPathComponent(".build/home-table-cards.png")
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        let dest = try #require(CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
    }
}
