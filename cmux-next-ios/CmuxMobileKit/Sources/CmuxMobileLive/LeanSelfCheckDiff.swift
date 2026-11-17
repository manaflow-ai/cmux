import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// One case of the lean terminal self-check, pixel for pixel: the grid as the PTY terminal drew
/// it against the same grid drawn from lean frames, both covering the same window rect. The
/// counts go to the Mac, whose host judges them (cmux-mobile-host `self_check.rs`, the simulator
/// pixel matrix's thresholds: at most 0.05% of the grid's pixels, 0.1% of each band).
///
/// A pixel differs when a channel differs by more than ``channelTolerance`` of 255 (GPU blend
/// rounding). The cursor cells are left out (the host checks the cursors' places instead).
/// Bands: the grid's first three rows (an agent CLI's header), its first column and its last.
struct LeanSelfCheckDiff {
    struct Band: Equatable {
        let name: String
        var differing = 0
        var compared = 0
    }

    static let channelTolerance = 24

    let differing: Int
    let compared: Int
    let bands: [Band]
    /// Red where they differ, the grid's outline yellow, the lean rendering dimmed elsewhere.
    let image: CGImage

    /// `pty` and `lean` cover `rect` (window points); `grid`, `cell` and `cursors` are in window
    /// points too. Nil when the images are not the same size or cannot be read.
    init?(pty: CGImage, lean: CGImage, rect: CGRect, grid: CGRect, cell: CGSize, cursors: [CGRect]) {
        guard pty.width == lean.width, pty.height == lean.height, rect.width > 0, rect.height > 0,
              let first = Self.pixels(pty), let second = Self.pixels(lean) else { return nil }
        let (width, height) = (pty.width, pty.height)
        let sx = CGFloat(width) / rect.width, sy = CGFloat(height) / rect.height
        func px(_ x: CGFloat) -> Int { Int(((x - rect.minX) * sx).rounded()) }
        func py(_ y: CGFloat) -> Int { Int(((y - rect.minY) * sy).rounded()) }
        let (gx0, gy0, gx1, gy1) = (px(grid.minX), py(grid.minY), px(grid.maxX), py(grid.maxY))
        let (x0, y0, x1, y1) = (max(0, gx0), max(0, gy0), min(width, gx1), min(height, gy1))
        let cursorBoxes = cursors.map { $0.insetBy(dx: -1, dy: -1) }.map { (px($0.minX), py($0.minY), px($0.maxX), py($0.maxY)) }
        let headerBottom = py(grid.minY + cell.height * 3)
        let firstColumnRight = px(grid.minX + cell.width)
        let lastColumnLeft = px(grid.maxX - cell.width)
        var bands = [Band(name: "header"), Band(name: "firstColumn"), Band(name: "lastColumn")]
        var out = [UInt8](repeating: 0, count: width * height * 4)
        var differing = 0
        var compared = 0
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let inGrid = x >= x0 && x < x1 && y >= y0 && y < y1
                let inCursor = cursorBoxes.contains { x >= $0.0 && x < $0.2 && y >= $0.1 && y < $0.3 }
                let counted = inGrid && !inCursor
                let delta = max(abs(Int(first[i]) - Int(second[i])), abs(Int(first[i + 1]) - Int(second[i + 1])),
                                abs(Int(first[i + 2]) - Int(second[i + 2])))
                let differs = counted && delta > 255  // RED: the diff sees no difference
                if counted {
                    compared += 1
                    if differs { differing += 1 }
                    if y < headerBottom { bands[0].compared += 1; if differs { bands[0].differing += 1 } }
                    if x < firstColumnRight { bands[1].compared += 1; if differs { bands[1].differing += 1 } }
                    if x >= lastColumnLeft { bands[2].compared += 1; if differs { bands[2].differing += 1 } }
                }
                let edge = inGrid && (x == x0 || x == x1 - 1 || y == y0 || y == y1 - 1)
                if differs {
                    out[i] = 255; out[i + 1] = 0; out[i + 2] = 0
                } else if edge {
                    out[i] = 255; out[i + 1] = 220; out[i + 2] = 0
                } else {
                    out[i] = second[i] / 3; out[i + 1] = second[i + 1] / 3; out[i + 2] = second[i + 2] / 3
                }
                out[i + 3] = 255
            }
        }
        guard let image = Self.image(out, width: width, height: height) else { return nil }
        self.differing = differing
        self.compared = compared
        self.bands = bands
        self.image = image
    }

    private static let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    /// RGBA bytes of `image`, top row first.
    static func pixels(_ image: CGImage) -> [UInt8]? {
        let (width, height) = (image.width, image.height)
        guard width > 0, height > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? bytes : nil
    }

    static func image(_ bytes: [UInt8], width: Int, height: Int) -> CGImage? {
        var bytes = bytes
        return bytes.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
    }

    /// `image` as PNG.
    static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
