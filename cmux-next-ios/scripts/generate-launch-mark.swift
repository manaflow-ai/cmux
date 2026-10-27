#!/usr/bin/env swift
// Draws the launch screen's cmux mark (App/Assets.xcassets/LaunchMark.imageset):
// the cmux chevron in the app icon's gradient with its soft glow, exactly as
// WelcomeMark draws it at gradient 1, glow 0.3 (CmuxMobileOnboarding/Welcome.swift),
// so the launch screen hands off to the first SwiftUI frame without a change.
//
// The chevron fills a 72 pt box (CmuxMark's geometry: web/public/cmux-icon.svg,
// x 91...179 and y 65...191 of 256, scaled to the box height and centered). The
// image is 104 pt square: the box plus 16 pt on every side for the glow, so
// iOS, which centers the launch image at its own size, centers the chevron
// where LaunchMarkView draws it. Light and dark differ only in the glow's
// strength, as in WelcomeMark.
//
// Usage: swift scripts/generate-launch-mark.swift   (from cmux-next-ios/)

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

private let box: CGFloat = 72
private let margin: CGFloat = 16
private let canvas = box + 2 * margin
/// WelcomeMark.iconGradient, sampled from AppIcon.icon, leading to trailing across the box.
private let stops: [(CGFloat, CGFloat, CGFloat)] = [(0x06, 0xCD, 0xFE), (0x2A, 0xA0, 0xF9), (0x51, 0x70, 0xF3)]
private let glowColor: (CGFloat, CGFloat, CGFloat) = (0x2A, 0xA0, 0xF9)
/// WelcomeMark's shadow at glow 0.3: opacity 0.3 (light) or 0.55 (dark) times
/// 0.3, radius 4 + 8 * 0.3 pt. A SwiftUI `.shadow(radius: r)` matches
/// CoreGraphics' `setShadow(blur: 2 * r)`.
private let glowRadius: CGFloat = 4 + 8 * 0.3
private let appearances: [(suffix: String, glowOpacity: CGFloat)] = [("", 0.3 * 0.3), ("-dark", 0.55 * 0.3)]

private let out = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("App/Assets.xcassets/LaunchMark.imageset")

private func srgb(_ c: (CGFloat, CGFloat, CGFloat), _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: c.0 / 255, green: c.1 / 255, blue: c.2 / 255, alpha: alpha)
}

/// CmuxMark's path in the 72 pt box, flipped for CoreGraphics' bottom-left origin.
private func chevron(in rect: CGRect) -> CGPath {
    let w: CGFloat = 88, h: CGFloat = 126
    let s = min(rect.width / w, rect.height / h)
    let ox = rect.midX - w * s / 2, top = rect.midY + h * s / 2
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + (x - 91) * s, y: top - (y - 65) * s) }
    let path = CGMutablePath()
    path.move(to: p(91, 65))
    for (x, y) in [(179, 128), (91, 191), (91, 151), (139, 128), (91, 105)] as [(CGFloat, CGFloat)] {
        path.addLine(to: p(x, y))
    }
    path.closeSubpath()
    return path
}

private func render(scale: CGFloat, glowOpacity: CGFloat) -> CGImage {
    let px = Int(canvas * scale)
    guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fatalError("no context") }
    ctx.scaleBy(x: scale, y: scale)
    let rect = CGRect(x: margin, y: margin, width: box, height: box)
    let path = chevron(in: rect)
    // SwiftUI's LinearGradient blends its stops in linear light; linear
    // sRGB comes closest to its colors (checked against an ImageRenderer render).
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.linearSRGB)!,
                              colors: stops.map { srgb($0) } as CFArray, locations: [0, 0.5, 1])!

    // The glow: the chevron's shadow, drawn once under the gradient fill.
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 2 * glowRadius * scale, color: srgb(glowColor, glowOpacity))
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    ctx.addPath(path)
    ctx.clip()
    ctx.drawLinearGradient(gradient, start: CGPoint(x: rect.minX, y: 0), end: CGPoint(x: rect.maxX, y: 0), options: [])
    ctx.endTransparencyLayer()
    ctx.restoreGState()
    return ctx.makeImage()!
}

private func write(_ image: CGImage, _ name: String) {
    let url = out.appendingPathComponent(name)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("cannot write \(url.path)")
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("cannot write \(url.path)") }
}

var images: [[String: Any]] = []
for (suffix, opacity) in appearances {
    for scale in [1, 2, 3] {
        let name = "launch-mark\(suffix)@\(scale)x.png"
        write(render(scale: CGFloat(scale), glowOpacity: opacity), name)
        var entry: [String: Any] = ["filename": name, "idiom": "universal", "scale": "\(scale)x"]
        if !suffix.isEmpty { entry["appearances"] = [["appearance": "luminosity", "value": "dark"]] }
        images.append(entry)
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let data = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try data.write(to: out.appendingPathComponent("Contents.json"))
print("wrote \(images.count) launch mark images")
