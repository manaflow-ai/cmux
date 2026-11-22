import CoreGraphics
import Testing
@testable import CmuxAgentBrands

@Suite struct AgentBrandRendererTests {
    private struct Pixel: Equatable {
        let r: UInt8, g: UInt8, b: UInt8, a: UInt8
    }

    private static let size = 128

    private func pixels(_ image: CGImage) throws -> [Pixel] {
        let context = try #require(CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = try #require(context.data).bindMemory(to: UInt8.self, capacity: image.width * image.height * 4)
        return (0..<(image.width * image.height)).map { i in
            Pixel(r: data[i * 4], g: data[i * 4 + 1], b: data[i * 4 + 2], a: data[i * 4 + 3])
        }
    }

    /// The pixel under a point given in the mark's view-box coordinates (top-left origin rows).
    private func pixel(_ all: [Pixel], at point: CGPoint, spec: AgentBrandSpec, style: AgentBrandStyle) throws -> Pixel {
        let rect = CGRect(x: 0, y: 0, width: Self.size, height: Self.size)
        let transform = try #require(AgentBrandRenderer.transform(for: spec, in: rect, style: style))
        let p = point.applying(transform)
        return all[Int(p.y) * Self.size + Int(p.x)]
    }

    @Test func everyMarkDrawsInBothStylesAndSchemes() throws {
        for brand in AgentBrandID.allCases {
            let spec = try #require(AgentBrandCatalog.spec(for: brand))
            for style in [AgentBrandStyle.mono, .brand] {
                for dark in [true, false] {
                    let image = try #require(AgentBrandRenderer.image(spec, pixelSize: Self.size, style: style, dark: dark))
                    let covered = try pixels(image).filter { $0.a > 128 }.count
                    // A mark covers a visible share of its square; a wordmark a smaller one.
                    #expect(covered > Self.size * Self.size / 30, "\(brand) \(style) dark=\(dark) covers \(covered) px")
                }
            }
        }
    }

    @Test func monoPaintsOnlyTheGivenColor() throws {
        let spec = try #require(AgentBrandCatalog.spec(for: .claude))
        let red = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        let image = try #require(AgentBrandRenderer.image(spec, pixelSize: Self.size, style: .mono, dark: true, monoColor: red))
        let opaque = try pixels(image).filter { $0.a == 255 }
        #expect(!opaque.isEmpty)
        #expect(opaque.allSatisfy { $0 == Pixel(r: 255, g: 0, b: 0, a: 255) })
    }

    @Test func brandToneFollowsTheScheme() throws {
        // The Blossom is white on dark surfaces and black on light ones.
        let spec = try #require(AgentBrandCatalog.spec(for: .openai))
        let onDark = try pixels(#require(AgentBrandRenderer.image(spec, pixelSize: Self.size, style: .brand, dark: true)))
        let onLight = try pixels(#require(AgentBrandRenderer.image(spec, pixelSize: Self.size, style: .brand, dark: false)))
        #expect(onDark.contains(Pixel(r: 255, g: 255, b: 255, a: 255)))
        #expect(onLight.contains(Pixel(r: 0, g: 0, b: 0, a: 255)))
        #expect(!onLight.contains(Pixel(r: 255, g: 255, b: 255, a: 255)))
    }

    @Test func tileShowsOnlyInTheBrandStyle() throws {
        // Kiro: the brand style draws the purple tile, whose corner area is empty in mono.
        let spec = try #require(AgentBrandCatalog.spec(for: .kiro))
        let brand = try pixels(#require(AgentBrandRenderer.image(spec, pixelSize: Self.size, style: .brand, dark: true)))
        let mono = try pixels(#require(AgentBrandRenderer.image(spec, pixelSize: Self.size, style: .mono, dark: true)))
        let nearCorner = CGPoint(x: 320, y: 1000)
        #expect(try pixel(brand, at: nearCorner, spec: spec, style: .brand) == Pixel(r: 0x90, g: 0x46, b: 0xFF, a: 255))
        #expect(try pixel(mono, at: CGPoint(x: 220, y: 220), spec: spec, style: .mono).a == 0)
        // The left eye is black in brand and a hole in mono.
        let eye = CGPoint(x: 636, y: 487)
        #expect(try pixel(brand, at: eye, spec: spec, style: .brand) == Pixel(r: 0, g: 0, b: 0, a: 255))
        #expect(try pixel(mono, at: eye, spec: spec, style: .mono).a == 0)
    }

    @Test func pathOverridesKeepTheirOwnTone() throws {
        // OpenCode's inner block is darker than its frame on dark surfaces.
        let spec = try #require(AgentBrandCatalog.spec(for: .opencode))
        let image = try pixels(#require(AgentBrandRenderer.image(spec, pixelSize: Self.size, style: .brand, dark: true)))
        #expect(try pixel(image, at: CGPoint(x: 30, y: 150), spec: spec, style: .brand) == Pixel(r: 0xF1, g: 0xEC, b: 0xEC, a: 255))
        #expect(try pixel(image, at: CGPoint(x: 120, y: 180), spec: spec, style: .brand) == Pixel(r: 0x4B, g: 0x46, b: 0x46, a: 255))
    }
}
