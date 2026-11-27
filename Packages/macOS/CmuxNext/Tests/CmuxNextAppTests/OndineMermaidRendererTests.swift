import AppKit
import CmuxHomeRender
@testable import CmuxNextHome
import Testing

/// Home chat's Mermaid renderer (user msg 2481 follow-up): Ondine runs in JavaScriptCore, its CSS
/// custom properties become concrete colours CoreSVG can paint, and the result is an image.
@Suite struct OndineMermaidRendererTests {
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let script = repoRoot.appending(path: "Resources/markdown-viewer/ondine.min.js")
    static let dark = HomeDiagramStyle(background: .rgb255(59, 59, 61), foreground: .gray255(225), accent: .rgb255(69, 140, 255))

    /// RGBA bytes of `image` and its bytes per row.
    static func pixels(_ image: CGImage) -> (bytes: [UInt8], perRow: Int) {
        let perRow = image.width * 4
        var bytes = [UInt8](repeating: 0, count: perRow * image.height)
        let ctx = CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: perRow,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        ctx?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return (bytes, perRow)
    }

    @Test func customPropertiesResolveToPaintCoreSVGDraws() throws {
        let svg = """
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 40 20" width="40" height="20" \
            style="max-width:100%;height:auto;--_bg:var(--ondine-bg,#fff);--_fg:var(--ondine-fg,#000);\
            --_a:var(--ondine-surface-alt,color-mix(in srgb,var(--_fg) 20%,var(--_bg)));color:var(--_fg)" fill="var(--_fg)">\
            <rect x="0" y="0" width="20" height="20" fill="var(--_fg)"/><rect x="20" y="0" width="20" height="20" fill="var(--_a)"/></svg>
            """
        let resolved = SVGCustomPropertyResolver().resolve(svg, overrides: ["--ondine-fg": "#ff0000", "--ondine-bg": "#0000ff"])
        #expect(!resolved.contains("var("))
        #expect(!resolved.contains("color-mix"))
        #expect(!resolved.contains("height:auto"))
        let image = try #require(SVGRasterizer().image(svg: resolved, size: CGSize(width: 40, height: 20), scale: 1))
        let (bytes, perRow) = Self.pixels(image)
        let left = 10 * perRow + 5 * 4, right = 10 * perRow + 30 * 4
        #expect(bytes[left] > 240 && bytes[left + 2] < 15, "var(--_fg) painted the override red")
        // color-mix(red 20%, blue): 51, 0, 204.
        #expect(abs(Int(bytes[right]) - 51) <= 3 && abs(Int(bytes[right + 2]) - 204) <= 3)
    }

    @Test func positionedLinesBecomeTheirOwnText() {
        let svg = #"<svg><text class="l" font-weight="bold"><tspan x="0" y="-5">A</tspan><tspan x="0" y="9">B</tspan></text><text x="1" y="2">C</text></svg>"#
        let flat = SVGTextFlattener().flatten(svg)
        #expect(!flat.contains("tspan"))
        #expect(flat.contains(#"<text class="l" font-weight="bold" x="0" y="-5">A</text>"#))
        #expect(flat.contains(#"<text class="l" font-weight="bold" x="0" y="9">B</text>"#))
        #expect(flat.contains(#"<text x="1" y="2">C</text>"#))
    }

    @Test func theBundledOndineDrawsAFlowchart() throws {
        let renderer = OndineMermaidRenderer(script: Self.script)
        let source = "flowchart TD\n  A[Start] --> B{Is it?}\n  B -->|Yes| C[OK]\n  B -->|No| D[End]"
        let size = try #require(renderer.layout(mermaid: source, maxWidth: 338))
        #expect(size.width > 20 && size.width <= 338 && size.height > 20)
        let image = try #require(renderer.image(mermaid: source, maxWidth: 338, style: Self.dark, scale: 2))
        #expect(image.width == Int((size.width * 2).rounded(.up)) && image.height == Int((size.height * 2).rounded(.up)))
        let (bytes, _) = Self.pixels(image)
        let inked = stride(from: 0, to: bytes.count, by: 4).filter { bytes[$0 + 3] > 0 && bytes[$0] > 150 }.count
        #expect(inked > 200, "labels and lines are drawn in the light foreground")
        #expect(renderer.layout(mermaid: source, maxWidth: 338) == size, "the same render, cached")
    }

    @Test func ondinesRealSVGHasNoCustomPropertyLeft() throws {
        let renderer = OndineMermaidRenderer(script: Self.script)
        for source in ["sequenceDiagram\n Alice->>Bob: Hi\n Note over Alice,Bob: a note", "pie title Pets\n \"Dogs\" : 386\n \"Cats\" : 85",
                       "classDiagram\n class Animal{\n +int age\n }"] {
            #expect(renderer.layout(mermaid: source, maxWidth: 338) != nil, "\(source)")
            #expect(renderer.image(mermaid: source, maxWidth: 338, style: Self.dark, scale: 1) != nil, "\(source)")
        }
        let svg = try #require(renderer.debugSVG(mermaid: "pie title Pets\n \"Dogs\" : 386\n \"Cats\" : 85", maxWidth: 338))
        let resolved = renderer.recoloured(svg, style: Self.dark)
        #expect(!resolved.contains("var("))
        #expect(!resolved.contains("tspan"))
        #expect(NSImage(data: Data(resolved.utf8))?.isValid == true)
    }

    @Test func aSourceOndineRefusesIsNil() {
        let renderer = OndineMermaidRenderer(script: Self.script)
        #expect(renderer.layout(mermaid: "this is not a diagram", maxWidth: 338) == nil)
        #expect(renderer.image(mermaid: "this is not a diagram", maxWidth: 338, style: Self.dark, scale: 2) == nil)
    }

    @Test func aMissingScriptRendersNothing() {
        let renderer = OndineMermaidRenderer(script: Self.repoRoot.appending(path: "no-such-ondine.js"))
        #expect(renderer.layout(mermaid: "graph TD\nA-->B", maxWidth: 338) == nil)
        #expect(OndineMermaidRenderer.bundled(appResources: Self.repoRoot.appending(path: "no-such-dir")) == nil)
    }
}
