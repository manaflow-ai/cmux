import AppKit
@testable import CmuxNextDesign
import Foundation
import Testing

/// The Computer Use drag rows (the setup's, the agent permission card's) draw Lucas's midnight cursor
/// tile, the one the composer's @computer-use and the setup window's head draw, never the helper
/// bundle's own icon (the generic blank app for a copy an older build staged).
@Suite struct ComputerUseAppIconTests {
    /// The tile the webviews draw (`toolMentions.ts` COMPUTER_USE_TILE): the source of the bundled icns.
    private static var webTile: URL {
        // Packages/macOS/CmuxNext/Tests/CmuxNextDesignTests/<this file>: six levels up is the repository root.
        (0..<6).reduce(URL(fileURLWithPath: #filePath)) { url, _ in url.deletingLastPathComponent() }
            .appending(path: "webviews/src/agent-session/acpmux/icons/computerUseTile.png")
    }

    /// `image` drawn into `side` x `side` RGBA pixels, `inset` (a fraction of the side) clear on every edge.
    private static func pixels(_ image: NSImage, side: Int, inset: CGFloat = 0) throws -> [UInt8] {
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                bytesPerRow: side * 4, bitsPerPixel: 32))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let margin = CGFloat(side) * inset
        image.draw(in: NSRect(x: margin, y: margin, width: CGFloat(side) - 2 * margin, height: CGFloat(side) - 2 * margin),
                   from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return Array(UnsafeBufferPointer(start: try #require(rep.bitmapData), count: side * side * 4))
    }

    @Test func bundledIconIsTheWebTile() throws {
        let bundled = try #require(ComputerUseAppIcon.tile)
        let web = try #require(NSImage(contentsOf: Self.webTile), "no tile at \(Self.webTile.path)")
        // The icns keeps 9% clear on each side (generate-computer-use-icon.sh); the tile fills its picture.
        let a = try Self.pixels(bundled, side: 64)
        let b = try Self.pixels(web, side: 64, inset: 0.09)
        let difference = zip(a, b).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) } / a.count
        // Resampling moves a channel by a few levels; another icon (the older gray cursor) by tens.
        #expect(difference <= 4, "ComputerUseIcon.icns is not computerUseTile.png: run scripts/cmux-next/generate-computer-use-icon.sh (mean difference \(difference))")
    }

    @Test func helperRowDrawsTheTileNotTheBundlesIcon() throws {
        // A helper staged by an older build: an Info.plist with no icon, so macOS draws the blank app.
        let root = FileManager.default.temporaryDirectory.appending(path: "cu-icon-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appending(path: "cmux DEV Helper.app", directoryHint: .isDirectory)
        let contents = app.appending(path: "Contents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.cmuxterm.app.debug.screen-sharing",
                                                              "CFBundlePackageType": "APPL"], format: .xml, options: 0)
            .write(to: contents.appending(path: "Info.plist"))
        let tile = try #require(ComputerUseAppIcon.tile)
        let row = ComputerUseAppIcon.image(forApp: app)
        #expect(try Self.pixels(row, side: 32) == Self.pixels(tile, side: 32))
        #expect(try Self.pixels(row, side: 32) != Self.pixels(NSWorkspace.shared.icon(forFile: app.path), side: 32))
    }
}
