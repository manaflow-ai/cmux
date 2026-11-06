import CoreGraphics

/// DEV and NIGHTLY (Debug menu > Sidebar States Playground): the favicons the playground's favicon rows show, drawn
/// here so the rows need no network: a dark one-color mark (GitHub-like, the hard case on a dark sidebar) and a
/// colorful one (Google-like). The favicon style variants (`sidebar.faviconStyle`) draw these through the real
/// `SidebarIconView` of each row.
struct SidebarStatesPlaygroundFavicons {
    /// The side of each favicon in pixels: a 2x 16 pt favicon.
    let side = 32

    /// A near-black disc with a ring cut out of it (transparent, as GitHub's mark cuts its cat out of the disc): a
    /// one-color mark. A ring painted white would make it a two-tone icon, which `sidebar.faviconStyle`'s adaptive
    /// tint leaves as fetched.
    var mono: CGImage? {
        draw { ctx, rect in
            ctx.setFillColor(CGColor(srgbRed: 0.09, green: 0.09, blue: 0.1, alpha: 1))
            ctx.fillEllipse(in: rect.insetBy(dx: 1, dy: 1))
            ctx.setBlendMode(.clear)
            ctx.setLineWidth(3)
            ctx.strokeEllipse(in: rect.insetBy(dx: 9, dy: 9))
        }
    }

    /// A ring in four colors (blue, red, yellow, green).
    var colorful: CGImage? {
        draw { ctx, rect in
            let colors = [CGColor(srgbRed: 0.26, green: 0.52, blue: 0.96, alpha: 1), CGColor(srgbRed: 0.92, green: 0.26, blue: 0.21, alpha: 1),
                          CGColor(srgbRed: 0.98, green: 0.74, blue: 0.02, alpha: 1), CGColor(srgbRed: 0.2, green: 0.66, blue: 0.33, alpha: 1)]
            let center = CGPoint(x: rect.midX, y: rect.midY)
            ctx.setLineWidth(7)
            for (index, color) in colors.enumerated() {
                ctx.setStrokeColor(color)
                ctx.addArc(center: center, radius: rect.width / 2 - 5, startAngle: CGFloat(index) * .pi / 2,
                           endAngle: CGFloat(index + 1) * .pi / 2, clockwise: false)
                ctx.strokePath()
            }
        }
    }

    private func draw(_ body: (CGContext, CGRect) -> Void) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        body(ctx, CGRect(x: 0, y: 0, width: side, height: side))
        return ctx.makeImage()
    }
}
