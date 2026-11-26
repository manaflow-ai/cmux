#if DEBUG
import AppKit
import CoreGraphics

/// DEBUG ONLY: the Before|After table playground's four pictures (Light and Dark, Before and After): a drawn
/// chat window whose After has a tidier sidebar, rounder bubbles and an accent badge, so every variant has a
/// real difference to show. Drawn once at 1600 × 1000 pixels (a 2x 800 × 500 shot).
@MainActor
struct HomeCompareFixture {
    /// Row 0 Light, row 1 Dark; column 0 Before, column 1 After.
    let pictures: [[CGImage]]
    let rowTitles = ["Light", "Dark"]
    let columnTitles = ["Before", "After"]

    init() {
        pictures = [false, true].map { dark in [false, true].compactMap { Self.draw(dark: dark, after: $0) } }
    }

    func picture(row: Int, column: Int) -> CGImage? { pictures[checked: row]?[checked: column] }

    /// Writes the pictures as PNGs into `folder` (Home's media folder: the only place a card draws pictures from) and returns the Markdown table naming them, with its files.
    func table(in folder: URL) -> HomeTable? {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var rows: [[String]] = []
        var files: [String: String] = [:]
        for (r, title) in rowTitles.enumerated() {
            var row = [title]
            for (c, column) in columnTitles.enumerated() {
                guard let image = picture(row: r, column: c) else { return nil }
                let url = folder.appendingPathComponent("compare-playground-\(title)-\(column).png".lowercased())
                guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]),
                      (try? png.write(to: url)) != nil else { return nil }
                row.append("![\(column)](\(url.path))")
                files[url.path] = url.path
            }
            rows.append(row)
        }
        return HomeTable(header: [""] + columnTitles, alignments: [.leading, .leading, .leading], rows: rows, pictures: files, loading: nil)
    }

    private static func draw(dark: Bool, after: Bool) -> CGImage? {
        let w = 1600, h = 1000
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 2, y: -2)
        func fill(_ rect: CGRect, _ gray: CGFloat, radius: CGFloat = 0, alpha: CGFloat = 1) {
            ctx.setFillColor(CGColor(gray: gray, alpha: alpha))
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.fillPath()
        }
        let bg: CGFloat = dark ? 0.12 : 0.98, side: CGFloat = dark ? 0.16 : 0.93, bubble: CGFloat = dark ? 0.24 : 0.89
        let ink: CGFloat = dark ? 0.82 : 0.28
        fill(CGRect(x: 0, y: 0, width: 800, height: 500), bg)
        // Title bar and its three dots.
        fill(CGRect(x: 0, y: 0, width: 800, height: 34), side)
        for (i, c) in [CGColor(red: 1, green: 0.37, blue: 0.34, alpha: 1), CGColor(red: 1, green: 0.74, blue: 0.18, alpha: 1),
                       CGColor(red: 0.16, green: 0.79, blue: 0.25, alpha: 1)].enumerated() {
            ctx.setFillColor(c)
            ctx.fillEllipse(in: CGRect(x: 14 + CGFloat(i) * 18, y: 11, width: 12, height: 12))
        }
        // Sidebar rows: Before's are cramped and uneven, After's even with a selected row.
        fill(CGRect(x: 0, y: 34, width: 190, height: 466), side)
        for i in 0..<7 {
            let y = 52 + CGFloat(i) * (after ? 34 : 26)
            if after && i == 0 { fill(CGRect(x: 10, y: y - 6, width: 170, height: 28), dark ? 0.3 : 0.84, radius: 8) }
            fill(CGRect(x: 20, y: y + 4, width: after ? 120 : CGFloat(70 + (i * 37) % 80), height: 8), ink, radius: 4, alpha: 0.55)
        }
        // Chat bubbles: After's are rounder and the reply has an accent badge.
        let r: CGFloat = after ? 16 : 6
        fill(CGRect(x: 220, y: 70, width: 330, height: 74), bubble, radius: r)
        fill(CGRect(x: 220, y: 160, width: 260, height: 50), bubble, radius: r)
        ctx.setFillColor(CGColor(red: 0.04, green: 0.52, blue: 1, alpha: 1))
        ctx.addPath(CGPath(roundedRect: CGRect(x: 520, y: 230, width: 250, height: 56), cornerWidth: r, cornerHeight: r, transform: nil))
        ctx.fillPath()
        for (i, y) in [86, 104, 122].enumerated() { fill(CGRect(x: 238, y: CGFloat(y), width: CGFloat(260 - i * 50), height: 8), ink, radius: 4, alpha: 0.6) }
        if after {
            ctx.setFillColor(CGColor(red: 0.2, green: 0.78, blue: 0.35, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: 756, y: 222, width: 22, height: 22))
        }
        // The message field.
        fill(CGRect(x: 220, y: 440, width: 560, height: after ? 40 : 32), dark ? 0.2 : 0.94, radius: after ? 20 : 6)
        return ctx.makeImage()
    }
}
#endif
