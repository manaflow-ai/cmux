import AppKit
@testable import CmuxNextDesign
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

/// Measurement only (not a regression test): how Liquid Glass composites while its window is key
/// and while it is not, over known backdrops, so the inactive wash can be derived from the tint
/// and opacity instead of a hardcoded alpha. Writes `glass-wash-measure.json` and a contact sheet
/// `glass-wash-measure.png` at the repository root.
@MainActor @Suite(.serialized, .timeLimit(.minutes(5))) struct GlassWashMeasureTests {
    final class KeyWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
    }

    struct RGB: Codable { var r: Double; var g: Double; var b: Double }

    struct Sample: Codable {
        var style: String
        var tint: RGB
        var opacity: Double
        var back: RGB
        var keyed: Bool
        var key: RGB
        var inactiveBare: RGB
        var inactiveFullWash: RGB
        var inactiveCurrent: RGB
        var keyUntinted: RGB
        var solvedWash: Double?
    }

    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    func mean(_ image: CGImage) -> RGB {
        let w = 16, h = 16
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            // The center half of the image, scaled down (averaged) to 16x16.
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: -CGFloat(w) / 2, y: -CGFloat(h) / 2, width: CGFloat(w) * 2, height: CGFloat(h) * 2))
        }
        var r = 0.0, g = 0.0, b = 0.0
        for i in 0..<(w * h) { r += Double(bytes[i * 4]); g += Double(bytes[i * 4 + 1]); b += Double(bytes[i * 4 + 2]) }
        let n = Double(w * h) * 255
        return RGB(r: r / n, g: g / n, b: b / n)
    }

    func settle(_ ms: Int = 450) async throws {
        CATransaction.flush()
        try await Task.sleep(for: .milliseconds(ms))
    }

    @Test func measureGlassKeyAndInactive() async throws {
        guard WindowScreenshotTests.hostShowsWindows() else { print("GLASSWASH no window server"); return }
        print("GLASSWASH liquidGlass=\(Glass.isLiquidGlassAvailable) os=\(ProcessInfo.processInfo.operatingSystemVersionString)")
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
        let frame = CGRect(x: 200, y: 200, width: 240, height: 160)
        let back = NSWindow(contentRect: frame.insetBy(dx: -30, dy: -30), styleMask: [.borderless], backing: .buffered, defer: false)
        back.isReleasedWhenClosed = false
        back.orderFrontRegardless()
        let front = KeyWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        front.isReleasedWhenClosed = false
        front.isOpaque = false
        front.backgroundColor = NSColor.white.withAlphaComponent(0.001)
        let thief = KeyWindow(contentRect: CGRect(x: 700, y: 200, width: 60, height: 60), styleMask: [.borderless], backing: .buffered, defer: false)
        thief.isReleasedWhenClosed = false
        thief.orderFrontRegardless()
        defer { front.close(); back.close(); thief.close() }

        let tints: [RGB] = [RGB(r: 0.11, g: 0.11, b: 0.14), RGB(r: 0.96, g: 0.95, b: 0.93), RGB(r: 0.10, g: 0.22, b: 0.55)]
        let opacities = [0.3, 0.55, 0.8]
        let backs: [RGB] = [RGB(r: 0, g: 0, b: 0), RGB(r: 1, g: 1, b: 1), RGB(r: 1, g: 0.5, b: 0)]
        let styles: [(String, Glass.Style)] = [("regular", .regular), ("clear", .clear)]
        var samples: [Sample] = []
        var sheet: [[CGImage]] = []

        for (styleName, style) in styles {
            for tint in tints {
                for opacity in opacities {
                    for backColor in backs {
                        back.backgroundColor = NSColor(srgbRed: backColor.r, green: backColor.g, blue: backColor.b, alpha: 1)
                        let content = NSView(frame: CGRect(origin: .zero, size: frame.size))
                        let glass = GlassPanelView(style: style)
                        glass.frame = content.bounds
                        glass.autoresizingMask = [.width, .height]
                        let tintColor = NSColor(srgbRed: tint.r, green: tint.g, blue: tint.b, alpha: opacity)
                        glass.tintColor = tintColor
                        content.addSubview(glass)
                        let wash = NSView(frame: content.bounds)
                        wash.wantsLayer = true
                        wash.layer?.backgroundColor = tintColor.cgColor
                        wash.layer?.opacity = 0
                        content.addSubview(wash)
                        front.contentView = content
                        front.makeKeyAndOrderFront(nil)
                        try await settle()
                        let keyed = front.isKeyWindow
                        func shot() -> CGImage? { front.compositedSnapshot(adding: [back], includeChild: { _ in true }) }
                        guard let keyImage = shot() else { print("GLASSWASH no capture"); return }
                        // Key, untinted.
                        glass.tintColor = nil
                        try await settle(250)
                        let keyUntinted = shot()
                        glass.tintColor = tintColor
                        thief.makeKeyAndOrderFront(nil)
                        try await settle()
                        guard let bare = shot() else { return }
                        CATransaction.begin(); CATransaction.setDisableActions(true)
                        wash.layer?.opacity = 1
                        CATransaction.commit()
                        try await settle(250)
                        let full = shot()
                        CATransaction.begin(); CATransaction.setDisableActions(true)
                        let lum = 0.2126 * tint.r + 0.7152 * tint.g + 0.0722 * tint.b
                        wash.layer?.opacity = lum > 0.5 ? 0.35 : 0.85
                        CATransaction.commit()
                        try await settle(250)
                        let current = shot()
                        let k = mean(keyImage), g0 = mean(bare)
                        // C(w) = G0 (1 - w) + F w, F = the composite at full wash (tint at its alpha).
                        let f = full.map(mean) ?? g0
                        var num = 0.0, den = 0.0
                        for (kc, gc, fc) in [(k.r, g0.r, f.r), (k.g, g0.g, f.g), (k.b, g0.b, f.b)] {
                            num += (kc - gc) * (fc - gc); den += (fc - gc) * (fc - gc)
                        }
                        let solved = den > 1e-5 ? num / den : nil
                        let sample = Sample(style: styleName, tint: tint, opacity: opacity, back: backColor, keyed: keyed, key: k,
                                            inactiveBare: g0, inactiveFullWash: f, inactiveCurrent: current.map(mean) ?? g0,
                                            keyUntinted: keyUntinted.map(mean) ?? k, solvedWash: solved)
                        samples.append(sample)
                        print("GLASSWASH \(styleName) tint=\(tint) a=\(opacity) back=\(backColor) keyed=\(keyed) key=\(k) bare=\(g0) full=\(f) cur=\(sample.inactiveCurrent) untinted=\(sample.keyUntinted) w=\(solved.map { String(format: "%.3f", $0) } ?? "-")")
                        sheet.append([keyImage, bare, full, current].compactMap { $0 })
                    }
                }
            }
        }
        let data = try JSONEncoder().encode(samples)
        try data.write(to: Self.repoRoot.appendingPathComponent("glass-wash-measure.json"))
        writeSheet(sheet, to: Self.repoRoot.appendingPathComponent("glass-wash-measure.png"))
    }

    func writeSheet(_ rows: [[CGImage]], to url: URL) {
        let cell = 96
        let columns = rows.map(\.count).max() ?? 0
        guard columns > 0, let context = CGContext(data: nil, width: cell * columns, height: cell * rows.count, bitsPerComponent: 8,
                                                   bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        for (y, row) in rows.enumerated() {
            for (x, image) in row.enumerated() {
                context.draw(image, in: CGRect(x: x * cell, y: (rows.count - 1 - y) * cell, width: cell, height: cell))
            }
        }
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}
