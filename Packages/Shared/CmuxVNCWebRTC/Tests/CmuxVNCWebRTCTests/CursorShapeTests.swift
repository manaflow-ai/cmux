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
        ScreenCursorShape(id: ScreenCursorShape.id(png: png, hotspot: CGPoint(x: 5, y: 5)), png: png.base64EncodedString(),
                          w: w, h: 0.04, hx: hx, hy: 0.125, pw: 28, ph: 40)
    }

    @Test func aViewerAsksForShapesBesideTelepointers() {
        let report = ScreenStreamViewer.drawPointersInput
        #expect(report.t == "caps")
        #expect(ScreenStreamHost.viewerDrawsPointers(report), "an older host still reads telepointers from it")
        #expect(ScreenStreamHost.viewerDrawsCursorShapes(report))
        #expect(!ScreenStreamHost.viewerDrawsCursorShapes(ScreenInput(t: "caps", s: "telepointers")), "an older viewer")
        #expect(!ScreenStreamHost.viewerDrawsCursorShapes(ScreenInput(t: "caps", s: "cursor-shape")), "shapes only with telepointers")
        #expect(!ScreenStreamHost.viewerDrawsCursorShapes(ScreenInput(t: "text", s: "telepointers,cursor-shape")))
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

    @Test func theIdFollowsTheImageAndHotspot() throws {
        let one = try Self.png()
        let two = try Self.png(width: 3)
        #expect(ScreenCursorShape.id(png: one, hotspot: .zero) == ScreenCursorShape.id(png: one, hotspot: .zero))
        #expect(ScreenCursorShape.id(png: one, hotspot: .zero) != ScreenCursorShape.id(png: two, hotspot: .zero))
        #expect(ScreenCursorShape.id(png: one, hotspot: .zero) != ScreenCursorShape.id(png: one, hotspot: CGPoint(x: 1, y: 0)))
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

    @Test func theHostSendsAShapeOnceUntilItForgetsIt() {
        var sent = ScreenStreamHost.SentCursorShapes()
        func send(_ id: String) -> Bool { sent.needsSend(id) }
        #expect(send("arrow"))
        #expect(!send("arrow"), "already sent")
        for index in 0 ..< ScreenStreamHost.SentCursorShapes.capacity - 1 { #expect(send("s\(index)")) }
        #expect(!send("arrow"), "used again: newest")
        #expect(send("one more"))
        #expect(send("s0"), "the oldest was forgotten and goes again")
        #expect(sent.ids.count == ScreenStreamHost.SentCursorShapes.capacity)
        sent.reset()
        #expect(send("arrow"), "another display: sent again")
    }

    @Test func aFailedShapeSendRetriesWithoutAnotherCursorRead() throws {
        var delivery = ScreenStreamHost.CursorShapeDelivery()
        let display = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let arrow = Self.shape(png: try Self.png())
        var writable = false
        var attempts: [String] = []
        func sample(_ read: ScreenCursorShape?) -> String? {
            delivery.current(read: read, display: display) { text in
                attempts.append(text)
                return writable
            }
        }
        #expect(sample(arrow) == nil, "a refused send must not advertise an undelivered shape")
        #expect(sample(nil) == nil, "an unchanged cursor still retries while the channel refuses it")
        writable = true
        #expect(sample(nil) == arrow.id, "the reader need not produce the unchanged shape again")
        #expect(sample(nil) == arrow.id)
        #expect(attempts.count == 3, "one attempt per sample until success, none after success")
        for text in attempts {
            let message = try JSONDecoder().decode(ScreenHostMessage.self, from: Data(text.utf8))
            #expect(message.t == ScreenHostMessage.cursorShapeType)
            #expect(message.cursor == arrow)
        }
    }

    @Test func aNewCursorSupersedesTheShapeWaitingToSend() throws {
        var delivery = ScreenStreamHost.CursorShapeDelivery()
        let display = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let arrow = Self.shape(png: try Self.png())
        let hand = Self.shape(png: try Self.png(width: 3))
        let latest = Self.shape(png: try Self.png(width: 4))
        var writable = true
        var attempts: [String] = []
        func sample(_ read: ScreenCursorShape?) -> String? {
            delivery.current(read: read, display: display) { text in
                attempts.append(text)
                return writable
            }
        }
        #expect(sample(arrow) == arrow.id)
        writable = false
        #expect(sample(hand) == arrow.id, "keep the last delivered cursor while the replacement waits")
        writable = true
        #expect(sample(latest) == latest.id)
        #expect(sample(nil) == latest.id)
        let messages = try attempts.map { try JSONDecoder().decode(ScreenHostMessage.self, from: Data($0.utf8)) }
        #expect(messages.map(\.t) == Array(repeating: ScreenHostMessage.cursorShapeType, count: 3))
        #expect(messages.compactMap(\.cursor) == [arrow, hand, latest], "the obsolete pending hand is not retried")
    }

    @Test func anotherDisplayDiscardsPendingShapesAndResendsItsGeometry() throws {
        var delivery = ScreenStreamHost.CursorShapeDelivery()
        let originalDisplay = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let otherDisplay = CGRect(x: 1512, y: 0, width: 756, height: 491)
        let arrow = Self.shape(png: try Self.png())
        let pending = Self.shape(png: try Self.png(width: 3))
        var resized = arrow
        resized.w *= 2
        resized.h *= 2
        var writable = true
        var attempts: [String] = []
        func sample(_ read: ScreenCursorShape?, on display: CGRect) -> String? {
            delivery.current(read: read, display: display) { text in
                attempts.append(text)
                return writable
            }
        }
        #expect(sample(arrow, on: originalDisplay) == arrow.id)
        writable = false
        #expect(sample(pending, on: originalDisplay) == arrow.id)
        writable = true
        #expect(sample(nil, on: otherDisplay) == nil, "the new display must not advertise old geometry")
        #expect(attempts.count == 2, "the previous display's pending shape must not be retried")
        #expect(sample(resized, on: otherDisplay) == resized.id)
        #expect(sample(nil, on: otherDisplay) == resized.id)
        let messages = try attempts.map { try JSONDecoder().decode(ScreenHostMessage.self, from: Data($0.utf8)) }
        #expect(messages.map(\.t) == Array(repeating: ScreenHostMessage.cursorShapeType, count: 3))
        #expect(messages.compactMap(\.cursor) == [arrow, pending, resized], "a known image id is resent with this display's dimensions")
    }

    /// macOS's cursor shadow, from the window server's cursor plists.
    @Test func theShadowIsMacOSs() {
        #expect(ScreenCursorShape.shadow.opacity == 0.45)
        #expect(ScreenCursorShape.shadow.blur == 2)
        #expect(ScreenCursorShape.shadow.offsetDown == 1)
    }

    #if os(macOS)
    /// A 28x40-point arrow (hotspot 5, 5) drawn at 2x on a 1512x982-point display.
    @Test func theHostSizesTheShapeAsFractionsOfTheDisplay() throws {
        let context = try #require(CGContext(data: nil, width: 56, height: 80, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        let rendered = ScreenCursorReader.Rendered(image: image, size: CGSize(width: 28, height: 40), hotspot: CGPoint(x: 5, y: 5))
        let display = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let shape = try #require(ScreenCursorReader.shape(rendered, display: display))
        #expect(abs(shape.w - 28.0 / 1512) < 1e-9 && abs(shape.h - 40.0 / 982) < 1e-9)
        #expect(abs(shape.hx - 5.0 / 28) < 1e-9 && abs(shape.hy - 5.0 / 40) < 1e-9)
        #expect(shape.pw == 28 && shape.ph == 40)
        let decoded = try #require(shape.image())
        #expect(decoded.width == 56 && decoded.height == 80, "the display's pixels, not its points")
        #expect(ScreenCursorReader.shape(rendered, display: .zero) == nil)
    }
    #endif
}
