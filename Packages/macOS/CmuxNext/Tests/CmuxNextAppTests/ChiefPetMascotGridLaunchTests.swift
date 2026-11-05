import AppKit
@testable import CmuxNextChiefPetWiring
import CmuxNextFloating
import Testing

/// The Chief Settings popover's character grid is built with Home, at launch, so building it reads
/// no picture file: each character's picture is read from its PNG only when its cell draws. Before,
/// each cell read its PNG and its size as it was made, and a cold launch's main thread waited in
/// `-[NSImage size]` (getattrlist) on those ten files past the nightly canary's 45 s wait for the
/// control socket.
@MainActor @Suite struct ChiefPetMascotGridLaunchTests {
    static let square = NSSize(width: ChiefPetMascotCell.pictureSide, height: ChiefPetMascotCell.pictureSide)

    @Test func buildingTheGridReadsNoPictureFile() throws {
        _ = NSApplication.shared
        let grid = ChiefPetMascotGrid(items: ChiefPetMascot.allCases.map { (id: $0.rawValue, title: $0.rawValue) })
        let characters = grid.cells.filter { $0.id != ChiefPetMascotGrid.uploadID }
        #expect(characters.map(\.id) == ChiefPetMascot.allCases.map(\.rawValue))
        for cell in characters {
            let image = try #require(cell.image, "\(cell.id) has no picture")
            #expect(image.size == Self.square, "\(cell.id)'s picture is not the cell's square")
            // A drawing handler's image has one custom rep; a file-backed one would have read the PNG.
            #expect(!image.representations.isEmpty && image.representations.allSatisfy { $0 is NSCustomImageRep },
                    "\(cell.id) read its PNG when the grid was built")
        }
    }

    @Test func eachCharacterStillDrawsItsPicture() throws {
        _ = NSApplication.shared
        for mascot in ChiefPetMascot.allCases {
            let image = ChiefPetSettingsRows.lazyThumbnail(of: mascot, side: ChiefPetMascotCell.pictureSide)
            let pixels = 44
            let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                       colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
            NSGraphicsContext.restoreGraphicsState()
            var inked = 0
            for x in 0..<pixels {
                for y in 0..<pixels where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 { inked += 1 }
            }
            #expect(inked > 0, "\(mascot.rawValue) draws nothing")
        }
    }
}
