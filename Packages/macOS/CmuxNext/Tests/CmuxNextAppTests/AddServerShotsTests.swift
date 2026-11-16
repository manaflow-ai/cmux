import AppKit
import CmuxNextDesign
import Foundation
import Testing

/// The contact sheet the shot tests share (Add Device, Add Machine, the right sidebar, SSH recovery,
/// joined machine rows): every state of a surface drawn into one PNG a fleet run returns as an
/// artifact. Kept from the Add Server shots, whose surface moved to the web page (its look is the
/// gallery's `pages.server-cards-add-server`).
@MainActor enum AddServerShotsTests {
    static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static func contactSheet(_ shots: [(String, NSImage)]) -> NSImage {
        let columns = 4, gap: CGFloat = 24, label: CGFloat = 22
        let cellWidth = shots.map(\.1.size.width).max() ?? 0
        let cellHeight = (shots.map(\.1.size.height).max() ?? 0) + label
        let rows = (shots.count + columns - 1) / columns
        let size = NSSize(width: CGFloat(columns) * (cellWidth + gap) + gap, height: CGFloat(rows) * (cellHeight + gap) + gap)
        let sheet = NSImage(size: size)
        sheet.lockFocus()
        NSColor(white: 0.12, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        for (index, shot) in shots.enumerated() {
            let column = index % columns, row = index / columns
            let x = gap + CGFloat(column) * (cellWidth + gap)
            let top = size.height - gap - CGFloat(row) * (cellHeight + gap)
            (shot.0 as NSString).draw(at: NSPoint(x: x, y: top - 16), withAttributes: [
                .font: NSFont.monospacedSystemFont(ofSize: TypeScale.detail, weight: TypeScale.regular),
                .foregroundColor: NSColor(white: 0.85, alpha: 1),
            ])
            shot.1.draw(in: NSRect(x: x, y: top - label - shot.1.size.height, width: shot.1.size.width, height: shot.1.size.height))
        }
        sheet.unlockFocus()
        return sheet
    }

    static func png(_ image: NSImage) throws -> Data {
        let tiff = try #require(image.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: tiff))
        return try #require(rep.representation(using: .png, properties: [:]))
    }
}
