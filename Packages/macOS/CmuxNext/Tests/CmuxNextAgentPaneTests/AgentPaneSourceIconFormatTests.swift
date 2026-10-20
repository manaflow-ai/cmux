import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import CmuxNextAgentPane

struct AgentPaneSourceIconFormatTests {
    @Test func pngInsideICOContainerDecodes() throws {
        let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
        // ICONDIR + ICONDIRENTRY: one 1x1 PNG payload at offset 22.
        var ico = Data([0, 0, 1, 0, 1, 0, 1, 1, 0, 0, 1, 0, 32, 0])
        for value in [UInt32(png.count), 22] {
            ico.append(contentsOf: (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
        }
        ico.append(png)
        try expectPNG(AgentPaneSourceIconPNG().decode(ico))
    }

    @Test func svgIsRefusedBeforeNativeRasterization() throws {
        let svg = Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="32" height="32"><rect width="32" height="32" fill="red"/></svg>"#.utf8)
        #expect(AgentPaneSourceIconPNG().decode(svg) == nil)
    }

    @Test(arguments: [
        "<?xml version='1.0'?><!-- comment --><svg xmlns='http://www.w3.org/2000/svg' width='32' height='32'/>",
        "\u{feff}  <svg xmlns='http://www.w3.org/2000/svg'><image href='https://tracker.example/pixel'/></svg>",
        "<!DOCTYPE svg PUBLIC 'anything'><svg width='32' height='32'/>",
    ])
    func disguisedSVGIsRefused(_ text: String) {
        let decoder = AgentPaneSourceIconPNG()
        #expect(decoder.decode(Data(text.utf8)) == nil)
        #expect(decoder.decode(text.data(using: .utf16LittleEndian)!) == nil)
        #expect(decoder.decode(text.data(using: .utf16BigEndian)!) == nil)
    }

    private func expectPNG(_ output: Data?) throws {
        let data = try #require(output)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        #expect(CGImageSourceGetType(source) as String? == UTType.png.identifier)
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width > 0 && image.width <= 64)
        #expect(image.height > 0 && image.height <= 64)
    }
}
