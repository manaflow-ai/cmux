@testable import CmuxNextComputerUse
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

/// The live preview card showed a black box around the app: the helper's JPEG frames paint the
/// window's transparent rounded corners black. The card clears them to the window's outline.
struct ComputerUseFrameCornersTests {
    /// A frame like the helper's: a gray window with rounded corners on black, as a JPEG.
    static func windowFrame(width: Int = 180, height: Int = 320, radius: CGFloat = 20,
                            background: CGFloat = 0, fill: CGFloat = 0.16) throws -> Data {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(CGColor(gray: background, alpha: 1))
        context.fill(bounds)
        context.setFillColor(CGColor(gray: fill, alpha: 1))
        context.addPath(CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.fillPath()
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    @Test func aWindowFramesBlackCornersAreCleared() throws {
        let frame = try #require(ComputerUseFrameCorners(Self.windowFrame()))
        let radius = try #require(frame.radius())
        #expect(abs(radius - 20) <= 4)
        let rounded = try #require(ComputerUseFrameCorners.clearingCorners(Self.windowFrame()))
        let out = try #require(ComputerUseFrameCorners(rounded))
        for (x, y) in [(0, 0), (179, 0), (0, 319), (179, 319)] {
            #expect(out.alpha(x: x, y: y) == 0)
        }
        #expect(out.alpha(x: 90, y: 160) == 255)
        #expect(out.alpha(x: 90, y: 0) == 255)
    }

    @Test func aFrameWithNoBlackCornersStaysAsItIs() throws {
        #expect(ComputerUseFrameCorners.clearingCorners(try Self.windowFrame(radius: 0)) == nil)
    }

    @Test func anAppWhoseOwnEdgeIsBlackStaysAsItIs() throws {
        #expect(ComputerUseFrameCorners.clearingCorners(try Self.windowFrame(fill: 0)) == nil)
    }

    /// The corner walk read past the pixels of a frame one pixel high or wide and crashed the app.
    @Test func aBlackFrameOnePixelHighOrWideStaysAsItIs() throws {
        for (width, height) in [(180, 1), (1, 180), (1, 1), (2, 2)] {
            let data = try Self.windowFrame(width: width, height: height, radius: 0, fill: 0)
            #expect(ComputerUseFrameCorners.clearingCorners(data) == nil)
        }
    }

    @Test func dataThatIsNotAnImageStaysAsItIs() {
        #expect(ComputerUseFrameCorners.clearingCorners(Data([0, 1, 2])) == nil)
    }
}
