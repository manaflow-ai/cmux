import AppKit
@testable import CmuxNextSidebar
import Foundation
import ImageIO
import Testing

/// Four visual treatments for a workspace inserted at the top. The selected `.snap` treatment leaves the
/// existing rows in their slots and lets only the new row fade in, so the list does not cascade.
/// Artifact: `sidebar-insert-motion-gallery.tar` (`CMUX_TEST_REQUIRE_GUI=1`).
@MainActor @Suite(.serialized) struct SidebarInsertMotionGalleryTests {
    private static let motions: [SidebarInsertMotion] = [.nudge, .quick, .snap, .spring]

    private final class Canvas: NSView {
        let motions: [SidebarInsertMotion]

        init(motions: [SidebarInsertMotion]) {
            self.motions = motions
            super.init(frame: .zero)
            wantsLayer = true
        }

        required init?(coder: NSCoder) { nil }

        override func draw(_ dirtyRect: NSRect) {
            let context = NSGraphicsContext.current?.cgContext
            context?.setFillColor(NSColor(calibratedWhite: 0.07, alpha: 1).cgColor)
            context?.fill(bounds)
            let panelWidth = bounds.width / CGFloat(motions.count)
            for (index, motion) in motions.enumerated() {
                let panel = CGRect(x: CGFloat(index) * panelWidth + 8, y: 8, width: panelWidth - 16, height: bounds.height - 16)
                draw(motion, in: panel, context: context)
            }
        }

        private func draw(_ motion: SidebarInsertMotion, in panel: CGRect, context: CGContext?) {
            let selected = motion == .snap
            let border = selected ? NSColor.systemGreen : NSColor(calibratedWhite: 0.25, alpha: 1)
            context?.setStrokeColor(border.cgColor)
            context?.setLineWidth(selected ? 2 : 1)
            context?.stroke(panel.insetBy(dx: 0.5, dy: 0.5))

            let title = motion.tunableTitle + (selected ? "  • default" : "")
            NSString(string: title).draw(at: CGPoint(x: panel.minX + 8, y: panel.maxY - 25), withAttributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: selected ? .semibold : .regular),
                .foregroundColor: selected ? NSColor.systemGreen : NSColor.white,
            ])

            let rowHeight: CGFloat = 20
            let gap: CGFloat = 5
            let startY = panel.maxY - 62
            let shift: CGFloat = motion == .nudge ? 6 : 20
            let newHeight: CGFloat = motion == .snap ? rowHeight : (motion == .nudge ? rowHeight - shift : 0)
            let oldStart = startY + rowHeight + gap
            let oldDrawY = motion == .snap ? oldStart : oldStart - shift
            drawRow(CGRect(x: panel.minX + 10, y: oldDrawY, width: panel.width - 20, height: rowHeight), color: .systemBlue, alpha: 0.9, context: context)
            drawRow(CGRect(x: panel.minX + 10, y: startY, width: panel.width - 20, height: newHeight), color: .systemGreen, alpha: newHeight > 0 ? 0.9 : 0.25, context: context)
            for row in 1..<4 {
                let target = startY - CGFloat(row) * (rowHeight + gap)
                let y = motion == .snap ? target : target - shift
                drawRow(CGRect(x: panel.minX + 10, y: y, width: panel.width - 20, height: rowHeight), color: .systemBlue, alpha: 0.9, context: context)
            }
            NSString(string: motion == .snap ? "existing rows land once" : "existing rows move").draw(
                at: CGPoint(x: panel.minX + 10, y: panel.minY + 12), withAttributes: [
                    .font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.secondaryLabelColor,
                ])
        }

        private func drawRow(_ rect: CGRect, color: NSColor, alpha: CGFloat, context: CGContext?) {
            context?.setFillColor(color.withAlphaComponent(alpha).cgColor)
            context?.fill(CGPath(roundedRect: rect, cornerWidth: 4, cornerHeight: 4, transform: nil))
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderMotionVariants() throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let out = root.appending(path: "sidebar-insert-motion-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let size = NSSize(width: 840, height: 220)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let canvas = Canvas(motions: Self.motions)
        canvas.frame = NSRect(origin: .zero, size: size)
        window.contentView = canvas
        window.orderFrontRegardless()
        canvas.displayIfNeeded()
        let rep = try #require(canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds))
        canvas.cacheDisplay(in: canvas.bounds, to: rep)
        let image = try #require(rep.cgImage)
        let url = out.appending(path: "variants.png")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        window.close()
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = root
        tar.arguments = ["cf", "sidebar-insert-motion-gallery.tar", "sidebar-insert-motion-gallery"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
    }
}
