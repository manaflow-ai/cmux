@testable import CmuxVNCWebRTC
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

/// The Mac's own cursor image on a screen stream: a viewer that says
/// `cursor-shape` gets each shape once and the telepointers name it.
struct CursorShapeTests {
    /// A 2x1 PNG: one opaque white pixel, one clear.
    static func png(width: Int = 2, height: Int = 1) throws -> Data {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1, height: height))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    static func shape(png: Data, w: Double = 0.02, hx: Double = 0.2) -> ScreenCursorShape {
        ScreenCursorShape(id: "5a1f", png: png.base64EncodedString(),
                          w: w, h: 0.04, hx: hx, hy: 0.125, pw: 28, ph: 40)
    }

    @Test func aViewerAsksForShapesBesideTelepointers() {
        let report = ScreenStreamViewer.drawPointersInput
        #expect(report.t == "caps")
        #expect(report.s?.contains("telepointers") == true, "an older host still reads telepointers from it")
        #expect(report.s?.contains("cursor-shape") == true)
        // Without the rules (cmux-rd-screen `screen_cursor_caps`) a host draws the cursor itself.
        let draws = ScreenStreamHost.viewerDraws(report, rules: ScreenRules())
        #expect(!draws.pointers && !draws.shapes)
    }

    @Test func theShapeAndTheTelepointersThatNameItRoundTrip() throws {
        let shape = Self.shape(png: try Self.png())
        var message = ScreenHostMessage(t: ScreenHostMessage.cursorShapeType)
        message.cursor = shape
        let decoded = try JSONDecoder().decode(ScreenHostMessage.self, from: JSONEncoder().encode(message))
        #expect(decoded.t == "cursor" && decoded.cursor == shape)
        var pointers = ScreenHostMessage(t: ScreenHostMessage.telepointersType)
        pointers.person = .init(x: 0.5, y: 0.5)
        pointers.shape = shape.id
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(pointers)) as? [String: Any])
        #expect(object["shape"] as? String == shape.id)
        // An older viewer decodes the telepointers and ignores the shape.
        #expect(!ScreenStreamViewer.isDisplays(decoded) && ScreenStreamViewer.capabilities(in: decoded) == nil)
    }

    @Test func aViewerDrawsOnlyAShapeItCan() throws {
        let png = try Self.png()
        let image = try #require(Self.shape(png: png).image())
        #expect(image.width == 2 && image.height == 1)
        #expect(Self.shape(png: png, w: 0).image() == nil, "no width")
        #expect(Self.shape(png: png, w: 1.5).image() == nil, "wider than the display")
        #expect(Self.shape(png: png, hx: -0.1).image() == nil, "a hotspot outside the cursor")
        var junk = Self.shape(png: png)
        junk.png = Data("not a png".utf8).base64EncodedString()
        #expect(junk.image() == nil)
        #expect(Self.shape(png: try Self.png(width: ScreenCursorShape.maxSide + 1)).image() == nil, "too large")
    }

    /// macOS's cursor shadow, from the window server's cursor plists.
    @Test func theShadowIsMacOSs() {
        #expect(ScreenCursorShape.shadow.opacity == 0.45)
        #expect(ScreenCursorShape.shadow.blur == 2)
        #expect(ScreenCursorShape.shadow.offsetDown == 1)
    }

    #if os(macOS)
    /// A 28x40-point arrow (hotspot 5, 5) drawn at 2x on a 1512x982-point display.
    @Test func withoutTheRulesTheHostSendsNoShape() throws {
        let context = try #require(CGContext(data: nil, width: 56, height: 80, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        let rendered = ScreenCursorReader.Rendered(image: image, size: CGSize(width: 28, height: 40), hotspot: CGPoint(x: 5, y: 5))
        let display = CGRect(x: 0, y: 0, width: 1512, height: 982)
        // The id is cmux-rd-screen's (`screen_cursor_shape`): without the rules there is no shape to send.
        #expect(ScreenCursorReader.shape(rendered, display: display, rules: ScreenRules()) == nil)
        #expect(ScreenCursorReader.shape(rendered, display: .zero, rules: ScreenRules()) == nil)
    }
    #endif
}
