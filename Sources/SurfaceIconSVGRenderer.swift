import Bonsplit
import CmuxControlSocket
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import SwiftDraw
import UniformTypeIdentifiers

/// Validates and rasterizes untrusted SVG icons on the socket's background worker.
struct SurfaceIconSVGRenderer: Sendable {
    enum RenderError: Error, Equatable {
        case requiresBackgroundThread
        case invalidAsset
        case invalidSVG
        case rasterizationFailed
    }

    func render(_ asset: ControlSurfaceIconAsset) throws -> TabIconAnimation {
        guard !Thread.isMainThread else { throw RenderError.requiresBackgroundThread }
        let side = 64
        guard (1...64).contains(asset.frames.count), asset.frames.count * side * side <= 262_144,
              asset.frames.indices.contains(asset.staticFrame),
              asset.frames.allSatisfy({ (50...5000).contains($0.durationMS) }),
              asset.frames.reduce(0, { $0 + $1.durationMS }) <= 30_000,
              asset.frames.reduce(0, { $0 + $1.svg.utf8.count }) <= 512 * 1024 else {
            throw RenderError.invalidAsset
        }
        let validator = SurfaceIconSVGValidator()
        // Validate the entire request before any third-party parsing or pixel allocation.
        for frame in asset.frames {
            do { try validator.validate(frame.svg) }
            catch { throw RenderError.invalidSVG }
        }
        var frames: [Data] = []
        for frame in asset.frames {
            try Task.checkCancellation()
            guard let svg = SVG(data: Data(frame.svg.utf8)),
                  svg.size.width.isFinite, svg.size.height.isFinite,
                  svg.size.width > 0, svg.size.height > 0,
                  let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: nil, width: side, height: side,
                                          bitsPerComponent: 8, bytesPerRow: side * 4,
                                          space: colorSpace,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw RenderError.rasterizationFailed
            }
            // CoreGraphics bitmap coordinates are bottom-up; SVG coordinates are top-down.
            context.translateBy(x: 0, y: CGFloat(side))
            context.scaleBy(x: 1, y: -1)
            context.draw(svg, in: CGRect(x: 0, y: 0, width: side, height: side))
            guard let image = context.makeImage() else { throw RenderError.rasterizationFailed }
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString,
                                                                    1, nil) else {
                throw RenderError.rasterizationFailed
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { throw RenderError.rasterizationFailed }
            frames.append(output as Data)
        }
        // Length-prefix frames and include every playback field so identity cannot alias definitions.
        var digest = SHA256()
        digest.update(data: Data("cmux-surface-icon-v1\u{0}".utf8))
        for (index, frame) in frames.enumerated() {
            digest.update(data: Data("\(frame.count):\(asset.frames[index].durationMS):".utf8))
            digest.update(data: frame)
        }
        digest.update(data: Data("\(asset.loop):\(asset.staticFrame)".utf8))
        return TabIconAnimation(id: digest.finalize().map { String(format: "%02x", $0) }.joined(),
                                frames: frames,
                                durations: asset.frames.map { Double($0.durationMS) / 1000 },
                                loops: asset.loop, staticFrameIndex: asset.staticFrame)
    }
}
