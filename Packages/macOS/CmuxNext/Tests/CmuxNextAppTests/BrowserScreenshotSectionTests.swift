import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextBrowser
import Foundation
import Testing

/// Screenshot Section (`browserScreenshotSection`): a drag over the page picks a rect, the page
/// snapshot is cropped to it and copied like Screenshot Page; Esc cancels. The action is bound
/// (not greyed out), and the selection maps a drag in the page view to the snapshot's pixels.
@MainActor @Suite(.serialized)
struct BrowserScreenshotSectionTests {
    @Test func screenshotSectionIsAvailable() {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        #expect(services.registry.unavailableReason(for: "browserScreenshotSection") == nil)
    }

    /// A drag in either direction gives the same rect, clamped to the page.
    @Test func dragGivesClampedRectInEitherDirection() throws {
        var forward = BrowserSectionSelection(bounds: CGRect(x: 0, y: 0, width: 100, height: 50))
        forward.begin(at: CGPoint(x: 10, y: 40))
        forward.drag(to: CGPoint(x: 30, y: 30))
        #expect(forward.rect == CGRect(x: 10, y: 30, width: 20, height: 10))

        var backward = BrowserSectionSelection(bounds: CGRect(x: 0, y: 0, width: 100, height: 50))
        backward.begin(at: CGPoint(x: 30, y: 30))
        backward.drag(to: CGPoint(x: 10, y: 40))
        #expect(backward.rect == forward.rect)

        var outside = BrowserSectionSelection(bounds: CGRect(x: 0, y: 0, width: 100, height: 50))
        outside.begin(at: CGPoint(x: 90, y: 10))
        outside.drag(to: CGPoint(x: 150, y: -20))
        #expect(outside.rect == CGRect(x: 90, y: 0, width: 10, height: 10))
    }

    /// A click or a tiny drag selects nothing (the overlay then cancels).
    @Test func tinyDragSelectsNothing() {
        var selection = BrowserSectionSelection(bounds: CGRect(x: 0, y: 0, width: 100, height: 50))
        #expect(selection.rect == nil)
        selection.begin(at: CGPoint(x: 10, y: 10))
        selection.drag(to: CGPoint(x: 11, y: 12))
        #expect(selection.rect == nil)
    }

    /// The crop follows the snapshot's scale (a 2x page) and its top-left pixel origin: a
    /// selection in the page's top half (red) gives only red pixels at twice the size.
    @Test func cropTakesTheSelectedPixels() throws {
        var selection = BrowserSectionSelection(bounds: CGRect(x: 0, y: 0, width: 100, height: 50))
        selection.begin(at: CGPoint(x: 10, y: 40))
        selection.drag(to: CGPoint(x: 30, y: 30))
        let page = try Self.halves(width: 200, height: 100)
        #expect(selection.pixelRect(imageWidth: 200, imageHeight: 100) == CGRect(x: 20, y: 20, width: 40, height: 20))
        let cropped = try #require(selection.crop(page))
        #expect(cropped.width == 40 && cropped.height == 20)
        #expect(try Self.colors(cropped) == [.red])

        var bottom = BrowserSectionSelection(bounds: CGRect(x: 0, y: 0, width: 100, height: 50))
        bottom.begin(at: CGPoint(x: 0, y: 0))
        bottom.drag(to: CGPoint(x: 100, y: 20))
        #expect(try Self.colors(try #require(bottom.crop(page))) == [.blue])
    }

    // MARK: Helpers

    enum Shade: Hashable { case red, blue, other }

    /// A page snapshot whose top half is red and bottom half blue.
    static func halves(width: Int, height: Int) throws -> CGImage {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height / 2))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: height / 2, width: width, height: height - height / 2))
        return try #require(context.makeImage())
    }

    /// The set of shades in `image`.
    static func colors(_ image: CGImage) throws -> Set<Shade> {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var shades = Set<Shade>()
        for index in stride(from: 0, to: pixels.count, by: 4) {
            switch (pixels[index], pixels[index + 1], pixels[index + 2]) {
            case (255, 0, 0): shades.insert(.red)
            case (0, 0, 255): shades.insert(.blue)
            default: shades.insert(.other)
            }
        }
        return shades
    }
}
