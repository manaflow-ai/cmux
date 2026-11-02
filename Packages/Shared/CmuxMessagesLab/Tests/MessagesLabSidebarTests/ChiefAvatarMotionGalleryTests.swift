import AppKit
import Testing
@testable import MessagesLabSidebar

/// The gallery of a Chief avatar's motion: for each style (rows) at idle and while working, one period
/// sampled into eight frames of a synthetic face, the loop's own keyframes applied. One sheet written to
/// the package's `.build/chief-avatar-motion-gallery.png` (ignored by git), which a fleet step returns
/// with `cmux-ci run --artifact Packages/Shared/CmuxMessagesLab/.build/chief-avatar-motion-gallery.png`.
@MainActor
@Suite(.serialized)
struct ChiefAvatarMotionGalleryTests {
    static let frames = 8
    static let cell: CGFloat = 56

    /// The face at one frame of `shape`: offset, scaled or turned about its centre as the layer would be.
    func drawFace(at origin: NSPoint, value: Double, keyPath: String) {
        let size: CGFloat = 36
        let transform = NSAffineTransform()
        transform.translateX(by: origin.x + Self.cell / 2, yBy: origin.y + Self.cell / 2)
        switch keyPath {
        case "transform.translation.y": transform.translateX(by: 0, yBy: -value * 4)  // 4x so a point reads on the sheet
        case "transform.scale": transform.scale(by: 1 + (value - 1) * 4)
        case "transform.rotation.z": transform.rotate(byRadians: value * 2)
        default: break
        }
        NSGraphicsContext.saveGraphicsState()
        transform.concat()
        let rect = NSRect(x: -size / 2, y: -size / 2, width: size, height: size)
        NSColor.systemOrange.setFill()
        NSBezierPath(ovalIn: rect).fill()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: -9, y: 2, width: 6, height: 6)).fill()
        NSBezierPath(ovalIn: NSRect(x: 3, y: 2, width: 6, height: 6)).fill()
        NSBezierPath(roundedRect: NSRect(x: -7, y: -9, width: 14, height: 4), xRadius: 2, yRadius: 2).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    @Test func drawsEveryStyleIdleAndWorking() throws {
        let styles = CmuxSidebarAvatarMotionStyle.allCases
        let modes: [SidebarAvatarMotion.Mode] = [.idle, .working]
        let gap: CGFloat = 16
        let strip = CGFloat(Self.frames) * Self.cell
        let sheet = NSImage(size: NSSize(width: CGFloat(modes.count) * (strip + gap) + gap,
                                         height: CGFloat(styles.count) * (Self.cell + gap) + gap))
        sheet.lockFocus()
        NSColor(white: 0.96, alpha: 1).setFill()
        NSRect(origin: .zero, size: sheet.size).fill()
        for (row, style) in styles.enumerated() {
            for (column, mode) in modes.enumerated() {
                let loop = SidebarAvatarMotion.animation(style, mode: mode, seed: "gallery")
                let values = try #require(loop.values as? [NSNumber]).map(\.doubleValue)
                #expect(values.count > Self.frames)
                for frame in 0..<Self.frames {
                    let value = values[frame * (values.count - 1) / Self.frames]
                    // Top row first: AppKit's y grows upward.
                    let origin = NSPoint(x: gap + CGFloat(column) * (strip + gap) + CGFloat(frame) * Self.cell,
                                         y: gap + CGFloat(styles.count - 1 - row) * (Self.cell + gap))
                    drawFace(at: origin, value: value, keyPath: try #require(loop.keyPath))
                }
            }
        }
        sheet.unlockFocus()
        let tiff = try #require(sheet.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let build = package.appendingPathComponent(".build")
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        try png.write(to: build.appendingPathComponent("chief-avatar-motion-gallery.png"))
    }
}
