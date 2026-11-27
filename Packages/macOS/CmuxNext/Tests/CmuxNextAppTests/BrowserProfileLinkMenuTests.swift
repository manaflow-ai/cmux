import AppKit
@testable import CmuxNextApp
import CmuxNextBrowser
import Testing

/// Open Link in Browser Profile ▸ lists the profiles with their names lined up: a profile's emoji
/// or symbol is the item's image, and a profile without one keeps an empty image of the same size,
/// so no name sits a column to the right of another.
@MainActor
struct BrowserProfileLinkMenuTests {
    @Test func namesLineUpWithOrWithoutAnEmoji() {
        var ran: [String] = []
        let items = BrowserProfileLinkMenu.profileItems([
            BrowserProfileRecord(id: "work", name: "Work", icon: "🦊"),
            BrowserProfileRecord(id: "personal", name: "Personal"),
            BrowserProfileRecord(id: "travel", name: "Travel", icon: "airplane"),
            // An icon the menu can't draw at this size (an uploaded image) keeps the empty image.
            BrowserProfileRecord(id: "school", name: "School", icon: "image:school"),
        ]) { ran.append($0.id) }
        #expect(items.map(\.title) == ["Work", "Personal", "Travel", "School"])
        let sizes = items.map { $0.image?.size }
        #expect(sizes.allSatisfy { $0 != nil && $0 == sizes.first! })
        #expect(items.map { Self.inked($0.image) } == [true, false, true, false])
        (items[1].target as? ActionMenuClosure)?.run()
        #expect(ran == ["personal"])
    }

    /// Whether `image` draws anything: an emoji or a symbol does, the spacer doesn't.
    private static func inked(_ image: NSImage?) -> Bool {
        guard let image, let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32,
                                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                       isPlanar: false, colorSpaceName: .deviceRGB,
                                                       bytesPerRow: 0, bitsPerPixel: 0) else { return false }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(x: 0, y: 0, width: 32, height: 32))
        NSGraphicsContext.restoreGraphicsState()
        return (0..<32).contains { x in (0..<32).contains { y in (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0 } }
    }
}
