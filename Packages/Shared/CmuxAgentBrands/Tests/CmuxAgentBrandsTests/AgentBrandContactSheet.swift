import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import CmuxAgentBrands

/// Writes every mark, in both styles on dark and light, to `$AGENT_BRANDS_SHEET_DIR/agent-brands.png`
/// for review. Skipped unless that variable is set.
@Suite struct AgentBrandContactSheet {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AGENT_BRANDS_SHEET_DIR"] != nil))
    func writeContactSheet() throws {
        let directory = try #require(ProcessInfo.processInfo.environment["AGENT_BRANDS_SHEET_DIR"])
        let cell = 72, mark = 40, columns = 4
        let brands = AgentBrandID.allCases
        let width = cell * columns, height = cell * brands.count
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let variants: [(AgentBrandStyle, Bool)] = [(.brand, true), (.mono, true), (.brand, false), (.mono, false)]
        for (row, brand) in brands.enumerated() {
            let spec = try #require(AgentBrandCatalog.spec(for: brand))
            for (column, variant) in variants.enumerated() {
                let (style, dark) = variant
                let x = column * cell, y = height - (row + 1) * cell
                context.setFillColor(dark ? CGColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1) : CGColor(srgbRed: 0.97, green: 0.97, blue: 0.96, alpha: 1))
                context.fill(CGRect(x: x, y: y, width: cell, height: cell))
                let inset = CGFloat(cell - mark) / 2
                AgentBrandRenderer.draw(
                    spec, in: context, rect: CGRect(x: CGFloat(x) + inset, y: CGFloat(y) + inset, width: CGFloat(mark), height: CGFloat(mark)),
                    style: style, dark: dark, monoColor: dark ? CGColor(gray: 0.92, alpha: 1) : CGColor(gray: 0.12, alpha: 1), flipped: false
                )
            }
        }
        let image = try #require(context.makeImage())
        let url = URL(fileURLWithPath: directory).appendingPathComponent("agent-brands.png")
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }
}
