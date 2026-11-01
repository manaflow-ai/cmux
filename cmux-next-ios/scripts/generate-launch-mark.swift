#!/usr/bin/env swift
// Writes the launch screen's cmux mark (App/Assets.xcassets/LaunchMark.imageset)
// from the chevron layer of the cmux app icon: the layer image of
// AppIcon.icon (the Icon Composer icon the Mac and iPhone apps ship), pixels
// unchanged apart from scaling, its glow included.
//
// The solid chevron (alpha >= 250) is 72 pt tall, the size the launch mark
// has always had, and sits at the image's center: the layer's glow margins
// are padded to the same width on opposite sides. iOS centers a launch image
// and SwiftUI centers a frame, so the launch screen and LaunchMarkView (the
// first SwiftUI frame) draw the chevron at the same spot. The same image
// serves light and dark.
//
// Usage: swift scripts/generate-launch-mark.swift   (from cmux-next-ios/)

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Height of the solid chevron, in points (CmuxLogoMark.imageChevronHeight;
/// the image height it prints is CmuxLogoMark.imageHeight).
private let chevronHeight: CGFloat = 72

private let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
private let icon = root.appendingPathComponent("../AppIcon.icon").standardizedFileURL
private let out = root.appendingPathComponent("App/Assets.xcassets/LaunchMark.imageset")

private func layerImage() -> CGImage {
    let json = icon.appendingPathComponent("icon.json")
    guard let doc = try? JSONSerialization.jsonObject(with: Data(contentsOf: json)) as? [String: Any],
          let groups = doc["groups"] as? [[String: Any]], groups.count == 1,
          let layers = groups[0]["layers"] as? [[String: Any]], layers.count == 1,
          let name = layers[0]["image-name"] as? String else {
        fatalError("\(json.path): expected one group with one layer (the chevron)")
    }
    let url = icon.appendingPathComponent("Assets/\(name)")
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fatalError("cannot read \(url.path)") }
    return image
}

private func context(_ width: Int, _ height: Int) -> CGContext {
    guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fatalError("no context") }
    return ctx
}

/// Pixel bounds (top-left origin, end exclusive) of the pixels with alpha >= `threshold`.
private func bounds(_ image: CGImage, alpha threshold: UInt8) -> (x0: Int, y0: Int, x1: Int, y1: Int) {
    let w = image.width, h = image.height
    let ctx = context(w, h)
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    let data = ctx.data!.assumingMemoryBound(to: UInt8.self)
    var x0 = w, y0 = h, x1 = -1, y1 = -1
    for y in 0..<h {
        for x in 0..<w where data[y * ctx.bytesPerRow + x * 4 + 3] >= threshold {
            x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
        }
    }
    return (x0, y0, x1 + 1, y1 + 1)
}

private let layer = layerImage()
private let solid = bounds(layer, alpha: 250)
private let glow = bounds(layer, alpha: 1)
/// Layer pixels per point.
private let density = CGFloat(solid.y1 - solid.y0) / chevronHeight
/// The canvas holds the whole glow around the centered solid chevron, in even
/// whole points so its center falls on a whole pixel at every scale.
private func evenPoints(_ solidPixels: Int, _ marginPixels: Int) -> CGFloat {
    let points = (CGFloat(solidPixels) + 2 * CGFloat(marginPixels)) / density
    return 2 * (points / 2).rounded(.up)
}
private let size = CGSize(
    width: evenPoints(solid.x1 - solid.x0, max(solid.x0 - glow.x0, glow.x1 - solid.x1)),
    height: evenPoints(solid.y1 - solid.y0, max(solid.y0 - glow.y0, glow.y1 - solid.y1))
)

private func render(scale: Int) -> CGImage {
    let s = CGFloat(scale)
    let ctx = context(Int(size.width * s), Int(size.height * s))
    ctx.interpolationQuality = .high
    // The layer, scaled, with its solid chevron's center on the canvas center
    // (CoreGraphics' origin is bottom-left; the bounds are top-left).
    let k = s / density
    let solidMidX = CGFloat(solid.x0 + solid.x1) / 2, solidMidY = CGFloat(solid.y0 + solid.y1) / 2
    let rect = CGRect(x: size.width * s / 2 - solidMidX * k,
                      y: size.height * s / 2 - (CGFloat(layer.height) - solidMidY) * k,
                      width: CGFloat(layer.width) * k, height: CGFloat(layer.height) * k)
    ctx.draw(layer, in: rect)
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

for old in (try? FileManager.default.contentsOfDirectory(atPath: out.path)) ?? [] where old.hasSuffix(".png") {
    try FileManager.default.removeItem(at: out.appendingPathComponent(old))
}
var images: [[String: Any]] = []
for scale in [1, 2, 3] {
    let name = "launch-mark@\(scale)x.png"
    write(render(scale: scale), name)
    images.append(["filename": name, "idiom": "universal", "scale": "\(scale)x"])
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let data = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try data.write(to: out.appendingPathComponent("Contents.json"))
print("wrote LaunchMark: \(Int(size.width)) x \(Int(size.height)) pt, chevron \(Int(chevronHeight)) pt tall")
