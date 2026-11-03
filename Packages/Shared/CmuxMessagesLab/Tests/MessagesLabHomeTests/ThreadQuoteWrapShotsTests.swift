import AppKit
import Testing
import UniformTypeIdentifiers
@testable import MessagesLabHome

/// The picture for the user's 2026-10-30 report ("make screenshots of fixing this, handle like multi-multi line"): my
/// outlined quote and the Chief's filled quote of a 1-, 2-, 3- and 5-line root (line counts in the 628 pt pane), in a 628 pt pane and a 1240 pt pane (the
/// user's wide Home pane), drawn by the real row renderer at 2x, dark on the left and light on the right, into
/// `.build/quote-wrap-shots.png` (a fleet step returns it with `--artifact`). It checks only that it drew;
/// `ThreadQuoteWrapTests` checks the text against the outline. Self-contained, so the same file draws an older tree.
@MainActor @Suite(.serialized) struct ThreadQuoteWrapShotsTests {
    static let texts = [
        "Reply-to-conversation UI is very bad.",
        "make sure the highlight color across everything in the app can be customized (and is consistent) based on the user's terminal theme",
        "another thing is i think platonic ideal for multiplayer app store is https://exe.dev/ where you can deploy somewhere and then pin stuff in workspaces, have panes that are remote exe.dev stuff etc",
        "Five lines: the reply quote of a long root shows every line of it, wrapped inside its outline the way a Messages bubble wraps. No word runs past the right end, no line is cut off at the left, and the tail still joins the one-line corner at the bottom right. Longer roots stop at eight lines and end in an ellipsis.",
    ]
    static let widths: [CGFloat] = [628, 1240]
    static let rowPitch: CGFloat = 110, scale: CGFloat = 2

    private func render(light: Bool, width: CGFloat) -> CGImage? {
        let saved = Fixture.lightAppearance
        Fixture.lightAppearance = light
        defer { Fixture.lightAppearance = saved }
        let height = Self.rowPitch * CGFloat(Self.texts.count * 2) + 20
        let w = Int(width * Self.scale), h = Int(height * Self.scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: Self.scale, y: -Self.scale)
        Fixture.withRenderScale(Self.scale) {
            ContextScope.run(ctx) {
                Fixture.background.setFill()
                ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
                var top: CGFloat = 20
                for outgoing in [true, false] {
                    for text in Self.texts {
                        let pv = ThreadPreview.make(root: PartRef(messageId: "root", partIndex: 0), part: .text(text, runs: []),
                                                    count: 2, outgoing: outgoing, width: width)
                        if outgoing {
                            PartRenderer.drawOutgoingThreadPreview(ctx, pv, top: top, rightEdge: Metrics(width: width).rightEdge)
                        } else {
                            PartRenderer.drawThreadPreview(ctx, pv, top: top, width: width)
                        }
                        top += Self.rowPitch
                    }
                }
            }
        }
        return ctx.makeImage()
    }

    @Test func quoteWrapDarkAndLight() throws {
        let gap = 30
        var tiles: [[CGImage]] = []
        for width in Self.widths {
            tiles.append([try #require(render(light: false, width: width)), try #require(render(light: true, width: width))])
        }
        let totalW = tiles.map { $0[0].width + gap + $0[1].width }.max() ?? 0
        let totalH = tiles.map { $0[0].height }.reduce(0, +) + gap * (tiles.count - 1)
        guard let ctx = CGContext(data: nil, width: totalW, height: totalH, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { Issue.record("no context"); return }
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: totalW, height: totalH))
        var y = totalH
        for pair in tiles {
            y -= pair[0].height
            ctx.draw(pair[0], in: CGRect(x: 0, y: y, width: pair[0].width, height: pair[0].height))
            ctx.draw(pair[1], in: CGRect(x: pair[0].width + gap, y: y, width: pair[1].width, height: pair[1].height))
            y -= gap
        }
        let image = try #require(ctx.makeImage())
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let out = package.appendingPathComponent(".build/quote-wrap-shots.png")
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        let dest = try #require(CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
    }
}
