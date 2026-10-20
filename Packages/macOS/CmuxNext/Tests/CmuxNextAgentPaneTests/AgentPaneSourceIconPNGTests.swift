import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import CmuxNextAgentPane

struct AgentPaneSourceIconPNGTests {
    private func raster(width: Int, height: Int, type: UTType = .png) throws -> Data {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        try #require(CGImageDestinationFinalize(destination))
        return data as Data
    }

    @Test func pngOutputPreservesAspectRatioAndDoesNotUpscale() throws {
        for (width, height, expectedWidth, expectedHeight) in [(512, 256, 64, 32), (256, 512, 32, 64), (16, 8, 16, 8)] {
            let input = try raster(width: width, height: height, type: .tiff)
            let data = try #require(AgentPaneSourceIconPNG().decode(input))
            let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
            #expect(CGImageSourceGetType(source) as String? == UTType.png.identifier)
            let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            #expect(image.width == expectedWidth)
            #expect(image.height == expectedHeight)
        }
    }

    @Test func invalidAndOversizedImagesAreRefused() throws {
        let decoder = AgentPaneSourceIconPNG()
        #expect(decoder.decode(Data([1])) == nil)
        #expect(decoder.decode(try raster(width: 4097, height: 1)) == nil)
        let vector = Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="100000" height="100000"><rect width="100000" height="100000" fill="red"/></svg>"#.utf8)
        #expect(decoder.decode(vector) == nil)
    }
}
