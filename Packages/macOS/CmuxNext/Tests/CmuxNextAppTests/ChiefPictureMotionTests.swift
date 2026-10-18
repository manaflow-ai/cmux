import AppKit
import CmuxNextDesign
@testable import CmuxNextHome
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

/// Chief picture motion (backgrounds plan phase 5): the native Home header always shows an
/// animated picture's still first frame (MessagesLab redraws it into a clipped disc), a still
/// picture as it is; `home.chiefPictureMotion`, which Home pages follow, is Never under Reduce
/// Motion.
@MainActor @Suite(.serialized) struct ChiefPictureMotionTests {
    static func gif() throws -> NSImage {
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, 2, nil))
        for red in [CGFloat(1), 0] {
            let context = try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                                 space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(red: red, green: 0, blue: 0, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
            CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        }
        #expect(CGImageDestinationFinalize(destination))
        return try #require(NSImage(data: data as Data))
    }

    static func frames(_ image: NSImage?) -> Int {
        (image?.representations.first as? NSBitmapImageRep)?.value(forProperty: .frameCount) as? Int ?? 1
    }

    @Test func theHeaderShowsAStillFrameAndReduceMotionMeansNever() throws {
        let animated = try Self.gif()
        #expect(Self.frames(animated) == 2)
        let still = HomeNativeTranscriptView.firstFrame(animated)
        #expect(Self.frames(still) == 1 && still.size == animated.size)
        let plain = NSImage(size: NSSize(width: 4, height: 4))
        #expect(HomeNativeTranscriptView.firstFrame(plain) === plain, "a still picture was redrawn")
        let motion = DesignSettings.shared.chiefPictureMotion
        defer {
            DesignSettings.shared.chiefPictureMotion = motion
            Motion.reduceMotionOverride = nil
        }
        Motion.reduceMotionOverride = false
        DesignSettings.shared.chiefPictureMotion = .always
        #expect(ChiefPictureMotion.effective == .always)
        Motion.reduceMotionOverride = true
        #expect(ChiefPictureMotion.effective == .never, "Reduce Motion lets a Chief picture move")
        Motion.reduceMotionOverride = false
        DesignSettings.shared.chiefPictureMotion = .hover
        #expect(ChiefPictureMotion.effective == .hover)
    }
}
