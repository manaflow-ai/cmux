import AppKit
@testable import CmuxNextDesign
import Testing

/// The safe wrappers that replaced raw pointer reads in CmuxNextDesign: a bitmap Swift owns and
/// reads by checked index, a typed associated-object slot, and the path, bitmap-context and TextKit calls without pointers.
struct MemorySafeDesignWrapperTests {
    @Test func drawnPixelsReadsTheDrawingTopRowFirst() throws {
        // A 4 x 2 RGBA bitmap with only its top-left pixel filled (CG draws y-up, so the top row is y = 1 there).
        let pixels = try #require(DrawnPixels(width: 4, height: 2, bytesPerPixel: 4, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue, draw: { context in
            context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 1, width: 1, height: 1))
        }))
        #expect(pixels.bytes.count == 4 * 2 * 4)
        #expect(pixels[0, 0, 0] == 255 && pixels[0, 0, 3] == 255)
        #expect(pixels[0, 1, 3] == 0)
        #expect(pixels[3, 0, 3] == 0)
    }

    @Test func drawnPixelsAlphaOnlyHasOneBytePerPixel() throws {
        let pixels = try #require(DrawnPixels(width: 3, height: 3, bytesPerPixel: 1, space: CGColorSpaceCreateDeviceGray(),
                                              bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue, draw: { context in
            context.fill(CGRect(x: 0, y: 0, width: 3, height: 3))
        }))
        #expect(pixels.bytes == [UInt8](repeating: 255, count: 9))
    }

    @Test func drawnPixelsRefusesAnEmptyBitmap() {
        var drew = false
        let none = DrawnPixels(width: 0, height: 4, bytesPerPixel: 4, space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue, draw: { _ in drew = true })
        #expect(none == nil)
        #expect(!drew)
    }

    @Test func objectAssociationKeepsOneValuePerSlotAndOwner() {
        let first = ObjectAssociation<NSString>(), second = ObjectAssociation<NSString>()
        let owner = NSObject(), other = NSObject()
        #expect(first.value(on: owner) == nil)
        first.set("a", on: owner)
        second.set("b", on: owner)
        #expect(first.value(on: owner) == "a")
        #expect(second.value(on: owner) == "b")
        #expect(first.value(on: other) == nil)
        first.set(nil, on: owner)
        #expect(first.value(on: owner) == nil)
        #expect(second.value(on: owner) == "b")
    }

    @Test func objectAssociationRetainsItsValueWithTheOwner() {
        let slot = ObjectAssociation<NSObject>()
        weak var kept: NSObject?
        var owner: NSObject? = NSObject()
        autoreleasepool {
            let value = NSObject()
            kept = value
            slot.set(value, on: owner!)
        }
        #expect(kept != nil)
        autoreleasepool { owner = nil }
        #expect(kept == nil)
    }

    @Test func pointerFreePathsCoverTheirShapes() {
        let box = CGRect(x: 10, y: 20, width: 40, height: 30)
        let rounded = CGPath.roundedRect(box, cornerWidth: 8, cornerHeight: 6)
        #expect(rounded.boundingBox == box)
        #expect(rounded.contains(CGPoint(x: box.midX, y: box.midY)))
        #expect(rounded.contains(CGPoint(x: box.minX + 0.5, y: box.midY)))
        #expect(!rounded.contains(CGPoint(x: box.minX + 0.5, y: box.minY + 0.5)))

        let square = CGPath.rect(box)
        #expect(square.boundingBox == box)
        #expect(square.contains(CGPoint(x: box.minX + 0.5, y: box.minY + 0.5)))
        #expect(!square.contains(CGPoint(x: box.maxX + 0.5, y: box.midY)))

        let oval = CGPath.ellipse(in: box)
        #expect(oval.boundingBox == box)
        #expect(oval.contains(CGPoint(x: box.midX, y: box.midY)))
        #expect(!oval.contains(CGPoint(x: box.minX + 1, y: box.minY + 1)))
    }

    @Test func pixelOwningBitmapDrawsAndRefusesAnEmptySize() throws {
        let context = try #require(CGContext.pixelOwningBitmap(width: 3, height: 2, space: CGColorSpaceCreateDeviceRGB(),
                                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 3, height: 2))
        let image = try #require(context.makeImage())
        #expect(image.width == 3 && image.height == 2)
        let alphaOnly = try #require(CGContext.pixelOwningBitmap(width: 4, height: 4, bytesPerRow: 4, space: CGColorSpaceCreateDeviceGray(),
                                                                bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue))
        #expect(alphaOnly.bytesPerRow == 4)
        #expect(CGContext.pixelOwningBitmap(width: 0, height: 4, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) == nil)
    }

    @Test func layoutManagerRangesWithoutOutParameters() {
        let font = NSFont.systemFont(ofSize: 13)
        let storage = NSTextStorage(string: "hello world", attributes: [.font: font])
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 1_000, height: 1_000))
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)

        let word = NSRange(location: 0, length: 5)
        let glyphs = manager.glyphRange(ofCharacters: word)
        #expect(glyphs == word)
        #expect(manager.characterRange(ofGlyphs: glyphs) == word)
        #expect(manager.lineFragmentRect(ofGlyphAt: 0).height > 0)
        let attributes = storage.attributes(atCharacter: 6)
        #expect((attributes[.font] as? NSFont) == font)
    }
}
