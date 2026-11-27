import AppKit
import CmuxNextDesign
@testable import CmuxNextLayout
import Foundation
import Testing

/// With CMUX_UNREAD_RING_GALLERY (a path relative to the repository root, or absolute) the gallery
/// test renders one unread pane's overlay as the person goes into it: the ring at rest, then
/// frames 0 to 1 s after the click read it, to that PNG. Core Animation does not render running
/// animations offscreen, so each frame sets every layer's opacity to its animation's value at that time.
@MainActor @Suite(.serialized) struct UnreadRingGalleryTests {
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let size = CGSize(width: 240, height: 150)
    static let times: [Double] = [0, 0.125, 0.25, 0.375, 0.5, 0.625, 0.75, 1]

    /// `animation`'s opacity at `time` seconds after it was added, nil when it is not an opacity animation then.
    static func opacity(_ animation: CAAnimation, at time: Double) -> Float? {
        let local = time - animation.beginTime
        guard local >= 0, animation.duration > 0, local <= animation.duration else { return nil }
        let fraction = local / animation.duration
        if let group = animation as? CAAnimationGroup {
            return (group.animations ?? []).compactMap { opacity($0, at: local) }.last
        }
        if let frames = animation as? CAKeyframeAnimation, frames.keyPath == "opacity" {
            let values = (frames.values ?? []).compactMap { ($0 as? NSNumber)?.doubleValue }
            guard values.count > 1 else { return values.first.map(Float.init) }
            let keys = frames.keyTimes?.map(\.doubleValue) ?? values.indices.map { Double($0) / Double(values.count - 1) }
            for index in 1..<values.count where fraction <= keys[index] {
                let span = max(keys[index] - keys[index - 1], 1e-9)
                let t = (fraction - keys[index - 1]) / span
                return Float(values[index - 1] + (values[index] - values[index - 1]) * t)
            }
            return values.last.map(Float.init)
        }
        if let basic = animation as? CABasicAnimation, basic.keyPath == "opacity",
           let from = (basic.fromValue as? NSNumber)?.doubleValue, let to = (basic.toValue as? NSNumber)?.doubleValue {
            return Float(from + (to - from) * fraction)
        }
        return nil
    }

    static func frame(_ overlay: PaneOverlayView, at time: Double?) throws -> CGImage {
        let scale = 2, width = Int(size.width) * scale, height = Int(size.height) * scale
        let srgb = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let ctx = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: srgb,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let root = try #require(overlay.layer)
        var saved: [(CALayer, Float)] = []
        if let time {
            for layer in root.sublayers ?? [] {
                let sampled = (layer.animationKeys() ?? []).compactMap { layer.animation(forKey: $0) }.compactMap { opacity($0, at: time) }.last
                if let sampled {
                    saved.append((layer, layer.opacity))
                    layer.opacity = sampled
                }
            }
        }
        defer { for (layer, value) in saved { layer.opacity = value } }
        ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        // The overlay is flipped; Core Graphics draws bottom-up.
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        root.render(in: ctx)
        return try #require(ctx.makeImage())
    }

    @Test func galleryOfAJumpToAnUnreadPane() throws {
        guard let path = ProcessInfo.processInfo.environment["CMUX_UNREAD_RING_GALLERY"] else { return }
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        _ = NSApplication.shared
        let overlay = PaneOverlayView(frame: CGRect(origin: .zero, size: Self.size))
        overlay.appearance = NSAppearance(named: .darkAqua)
        overlay.setShape(padding: 6, cornerRadius: 10, headerHeight: 0)
        func show(_ mark: AttentionMark?, readByEntry: Bool) {
            overlay.update(showsRing: false, dim: 0, focusRing: FocusRingSettings(), border: .init(shows: false),
                           attention: mark, attentionSettings: AttentionSettings(), readByEntry: readByEntry, animated: true)
        }
        show(AttentionMark(generation: 4), readByEntry: false)
        var frames = [try Self.frame(overlay, at: nil)]
        // The person clicks into the pane: the mark goes, read by entry.
        show(nil, readByEntry: true)
        for time in Self.times { frames.append(try Self.frame(overlay, at: time)) }

        let w = frames[0].width, h = frames[0].height, gap = 8
        let srgb = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let ctx = try #require(CGContext(data: nil, width: (w + gap) * frames.count, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: srgb,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        for (index, image) in frames.enumerated() { ctx.draw(image, in: CGRect(x: index * (w + gap), y: 0, width: w, height: h)) }
        let image = try #require(ctx.makeImage())
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : Self.repoRoot.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
    }
}
