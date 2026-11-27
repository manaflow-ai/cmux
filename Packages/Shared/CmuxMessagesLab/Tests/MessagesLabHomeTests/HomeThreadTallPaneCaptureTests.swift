import AppKit
@testable import CmuxHomeCore
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import MessagesLabHome

/// The picture of a reply view in a tall pane (Lawrence 2026-10-28: "unable to scroll down here"):
/// the real Home view over the mock owner, 1300 pt tall, a 60-line message opened in Reply…, drawn
/// to `.build/home-thread-tall-pane.png` (a fleet step returns it with `--artifact`). It checks only
/// that it drew; the picture is for people. `HomeThreadScrollTests` checks the place.
@MainActor @Suite(.serialized) struct HomeThreadTallPaneCaptureTests {
    @Test func aReplyViewInATallPane() async throws {
        let rig = try await HomeChatRig(history: 4, height: 1300)
        defer { rig.stop() }
        await rig.send((1...60).map { "\(HomeChatRig.tag) line \($0) of a long report Hgjpqy" }.joined(separator: "\n"))
        for _ in 0..<4 { rig.frame() }
        try #require(rig.view.debugReplyNewest(mine: true) != nil, "Reply… opened no view")
        // Row bitmaps draw off main and the open flies: give them a few frames.
        for _ in 0..<12 {
            rig.frame()
            try await Task.sleep(for: .milliseconds(150))
        }
        let layer = try #require(rig.view.layer)
        let scale: CGFloat = 2
        let size = rig.view.bounds.size
        let ctx = try #require(CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                                         bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.scaleBy(x: scale, y: scale)
        // The view's layers are y-down (a flipped NSView); a bitmap context is y-up.
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        layer.render(in: ctx)
        // The rows' real frames (red) and the field's top (yellow): the bitmap render can lag the frames.
        let demo = try #require(rig.view.controller.demo)
        ctx.setLineWidth(2)
        ctx.setStrokeColor(CGColor(red: 1, green: 0.2, blue: 0.2, alpha: 1))
        for v in demo.threadViews { ctx.stroke(v.frame.insetBy(dx: 2, dy: RowDraw.margin)) }
        ctx.setStrokeColor(CGColor(red: 1, green: 0.9, blue: 0, alpha: 1))
        ctx.stroke(CGRect(x: 0, y: demo.fieldTop, width: size.width, height: 0))
        let image = try #require(ctx.makeImage())
        // The package directory: this file is Tests/MessagesLabHomeTests/<name>.swift.
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let out = package.appendingPathComponent(".build/home-thread-tall-pane.png")
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        let dest = try #require(CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
    }
}
