import AppKit
import Testing
import UniformTypeIdentifiers
@testable import MessagesLabHome

/// The before/after picture of the reply quote's tail (user, 2026-10-30: "bottom right thing still looks bad
/// (multiline stuff)"): my outlined quote and the Chief's filled quote with 1, 2 and 3 lines, drawn by the real
/// row renderer at 3x, dark on the left and light on the right, into `.build/quote-tail-shots.png` (a fleet step
/// returns it with `--artifact`). It checks only that it drew; `ThreadQuoteTailJoinTests` checks the geometry.
@MainActor @Suite(.serialized) struct ThreadQuoteTailShotsTests {
    static let texts = [
        ThreadQuoteTailJoinTests.short,
        ThreadQuoteTailJoinTests.long,
        ThreadQuoteTailJoinTests.three,
    ]
    static let width: CGFloat = 628, rowPitch: CGFloat = 78, scale: CGFloat = 3

    private func render(light: Bool) -> CGImage? {
        let saved = Fixture.lightAppearance
        Fixture.lightAppearance = light
        defer { Fixture.lightAppearance = saved }
        let height = Self.rowPitch * CGFloat(Self.texts.count * 2) + 20
        let w = Int(Self.width * Self.scale), h = Int(height * Self.scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: Self.scale, y: -Self.scale)
        Fixture.withRenderScale(Self.scale) {
            ContextScope.run(ctx) {
                Fixture.background.setFill()
                ctx.fill(CGRect(x: 0, y: 0, width: Self.width, height: height))
                var top: CGFloat = 20
                for outgoing in [true, false] {
                    for text in Self.texts {
                        let pv = ThreadPreview.make(root: PartRef(messageId: "root", partIndex: 0), part: .text(text, runs: []),
                                                    count: 4, outgoing: outgoing, width: Self.width)
                        if outgoing {
                            PartRenderer.drawOutgoingThreadPreview(ctx, pv, top: top, rightEdge: Fixture.rightEdge)
                        } else {
                            PartRenderer.drawThreadPreview(ctx, pv, top: top, width: Self.width)
                        }
                        top += Self.rowPitch
                    }
                }
            }
        }
        return ctx.makeImage()
    }

    @Test func quoteTailsDarkAndLight() throws {
        let dark = try #require(render(light: false))
        let light = try #require(render(light: true))
        let gap = 30
        guard let ctx = CGContext(data: nil, width: dark.width + gap + light.width, height: max(dark.height, light.height),
                                  bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { Issue.record("no context"); return }
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        ctx.draw(dark, in: CGRect(x: 0, y: ctx.height - dark.height, width: dark.width, height: dark.height))
        ctx.draw(light, in: CGRect(x: dark.width + gap, y: ctx.height - light.height, width: light.width, height: light.height))
        let image = try #require(ctx.makeImage())
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let out = package.appendingPathComponent(".build/quote-tail-shots.png")
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        let dest = try #require(CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
    }
}
