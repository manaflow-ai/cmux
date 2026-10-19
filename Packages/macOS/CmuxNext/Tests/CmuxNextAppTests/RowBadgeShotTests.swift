import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Scratch only (never merged): renders row badges to PNG and prints them base64 for PR screenshots.
@MainActor @Suite struct RowBadgeShotTests {
    @Test func shots() throws {
        let scale: CGFloat = 4
        let rowColor = NSColor(calibratedWhite: 0.93, alpha: 1).cgColor
        let iconColor = NSColor(calibratedRed: 0.36, green: 0.55, blue: 0.95, alpha: 1).cgColor
        let chipColor = NSColor(calibratedWhite: 0.82, alpha: 1).cgColor
        let rows: [(String, [StatusIndicatorState], RowBadgeView.Look)] = [
            ("corner-working", [.working], .corner), ("corner-done", [.success], .corner),
            ("stack-working", [.working, .waiting, .error], .stack), ("stack-done", [.success, .waiting, .error], .stack),
        ]
        for (name, states, look) in rows {
            let host = NSView(frame: NSRect(x: 0, y: 0, width: 72, height: 28))
            host.wantsLayer = true
            host.layer?.backgroundColor = rowColor
            let icon = CALayer()
            icon.frame = CGRect(x: 4, y: 4, width: 20, height: 20)
            icon.cornerRadius = 5
            icon.backgroundColor = iconColor
            host.layer?.addSublayer(icon)
            let badge = RowBadgeView(frame: NSRect(x: look == .corner ? 16 : 28, y: 0, width: 44, height: look == .corner ? 14 : 28))
            badge.ringColor = rowColor
            badge.chipColor = chipColor
            host.addSubview(badge)
            badge.configure(states, look: look)
            host.layoutSubtreeIfNeeded()
            badge.layoutSubtreeIfNeeded()
            for glyph in badge.subviews { glyph.layer?.removeAllAnimations(); glyph.layer?.sublayers?.forEach { $0.removeAllAnimations() } }
            let width = Int(host.bounds.width * scale), height = Int(host.bounds.height * scale)
            let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                                 space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.scaleBy(x: scale, y: scale)
            host.layer?.render(in: context)
            let image = try #require(context.makeImage())
            let data = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            print("BADGE_SHOT \(name) \(data.base64EncodedString())")
        }
    }
}
