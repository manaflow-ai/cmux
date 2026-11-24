import AppKit
import CmuxNextDesign
import Foundation

/// Lays labelled renders into one contact sheet a fleet run returns (`cmux-ci run ... --artifact
/// Packages/macOS/CmuxNext/.build/NAME.png`). The concentric-corner shot suites share it; it lived in the pane ⋮'s shot
/// suite until that button went (#53378).
@MainActor struct ShotContactSheet {
    /// `Packages/macOS/CmuxNext`, where a shot suite writes its sheet under `.build/`.
    static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// `shots` in two columns, each under its label, on a dark ground.
    static func image(_ shots: [(String, CGImage)]) -> CGImage {
        let gap = 24, label = 36
        let cellWidth = shots.map(\.1.width).max() ?? 0, cellHeight = (shots.map(\.1.height).max() ?? 0) + label
        let columns = 2, rows = (shots.count + columns - 1) / columns
        let width = columns * (cellWidth + gap) + gap, height = rows * (cellHeight + gap) + gap
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(white: 0.12, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        for (index, shot) in shots.enumerated() {
            let column = index % columns, row = index / columns
            let x = CGFloat(gap + column * (cellWidth + gap))
            let top = CGFloat(height - gap - row * (cellHeight + gap))
            (shot.0 as NSString).draw(at: NSPoint(x: x, y: top - 26), withAttributes: [
                .font: NSFont.monospacedSystemFont(ofSize: TypeScale.title, weight: TypeScale.regular),
                .foregroundColor: NSColor(white: 0.85, alpha: 1),
            ])
            let image = NSImage(cgImage: shot.1, size: NSSize(width: shot.1.width, height: shot.1.height))
            image.draw(in: NSRect(x: x, y: top - CGFloat(label + shot.1.height), width: CGFloat(shot.1.width), height: CGFloat(shot.1.height)))
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage!
    }
}
