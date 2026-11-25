import AppKit
@testable import CmuxHomeCore
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import MessagesLabHome

/// The real Home view over the mock owner after a person's message and a failed Chief turn, light
/// and dark, drawn into `.build/turn-failure-shots.zip` (a fleet step returns it with
/// `--artifact Packages/Shared/CmuxMessagesLab/.build/turn-failure-shots.zip`). It reads only the
/// rig and the posted text, so the same file draws the old raw line and the new card.
@MainActor @Suite(.serialized) struct HomeTurnFailureShotsTests {
    private func render(_ view: NSView) throws -> CGImage {
        let layer = try #require(view.layer)
        let scale: CGFloat = 2
        let size = view.bounds.size
        let ctx = try #require(CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                                         bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(Fixture.background.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        ctx.scaleBy(x: scale, y: scale)
        // The view's layers are y-down (a flipped NSView); a bitmap context is y-up.
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        layer.render(in: ctx)
        let full = try #require(ctx.makeImage())
        // The bottom of the pane: the box and the last messages above it.
        let keep = Int(min(size.height, 420) * scale)
        return try #require(full.cropping(to: CGRect(x: 0, y: full.height - keep, width: full.width, height: keep)))
    }

    @Test func aFailedTurnRendersToTheShots() async throws {
        _ = NSApplication.shared
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let out = package.appendingPathComponent(".build/turn-failure-shots", isDirectory: true)
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let saved = Fixture.lightAppearance
        defer { Fixture.lightAppearance = saved }
        let scenes = [
            ("network", "Let me check the build.\n\n(turn failed on claude: fetch failed)"),
            ("limit", "(turn failed: You've hit your weekly limit · resets Nov 12 at 9pm (America/Los_Angeles))"),
        ]
        for light in [false, true] {
            Fixture.lightAppearance = light
            for (name, text) in scenes {
                let rig = try await HomeChatRig(history: 0, width: 520, height: 520)
                rig.window.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
                rig.view.onChiefRetry = { _ in }
                _ = await rig.send("\(HomeChatRig.tag) is the build green?")
                _ = await rig.post(text, key: IdempotencyKey("shot-\(UUID().uuidString)"))
                rig.view.projection.refresh()
                for _ in 0..<6 { rig.frame() }
                let image = try render(rig.view)
                let file = out.appendingPathComponent("\(name)-\(light ? "light" : "dark").png")
                let dest = try #require(CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil))
                CGImageDestinationAddImage(dest, image, nil)
                #expect(CGImageDestinationFinalize(dest))
                rig.stop()
            }
        }
        let zip = package.appendingPathComponent(".build/turn-failure-shots.zip")
        try? FileManager.default.removeItem(at: zip)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--keepParent", out.path, zip.path]
        try ditto.run()
        ditto.waitUntilExit()
        #expect(ditto.terminationStatus == 0)
    }
}
