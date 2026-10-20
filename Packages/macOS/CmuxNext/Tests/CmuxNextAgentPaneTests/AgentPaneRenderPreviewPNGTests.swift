import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import CmuxNextAgentPane

struct AgentPaneRenderPreviewPNGTests {
    @Test func retinaSnapshotsEncodeAtOneXAndRespectTheLongEdge() throws {
        for (width, height) in [(390, 120), (1440, 1600)] {
            let context = try #require(CGContext(data: nil, width: width * 2, height: height * 2,
                                                bitsPerComponent: 8, bytesPerRow: 0,
                                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(gray: 0.5, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width * 2, height: height * 2))
            let image = try #require(context.makeImage())
            let json = try AgentPaneRenderPreviewPNG().encode(image, width: width, height: height, report: Data("{\"contentHeight\":2000}".utf8))
            let result = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            let base64 = try #require(result["png"] as? String)
            #expect(base64.utf8.count <= 4 << 20)
            let data = try #require(Data(base64Encoded: base64))
            let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
            let raster = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            #expect(raster.width <= width)
            #expect(raster.height <= height)
            #expect(max(raster.width, raster.height) <= 1568)
            #expect(result["contentHeight"] as? Int == 2000)
            #expect(result["width"] as? Int == raster.width)
            #expect(result["capturedHeight"] as? Int == raster.height)
        }
    }
}
