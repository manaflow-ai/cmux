public import CoreGraphics
public import Foundation

/// A flattened RGBA pixel buffer captured from a terminal panel's `CGImage`,
/// used by the debug `panel_snapshot` command to detect frame-to-frame change.
///
/// The buffer is premultiplied-last, big-endian 32-bit RGBA at 8 bits per
/// component, matching the `CGContext` the snapshot is drawn through.
public struct PanelSnapshotState: Sendable {
    /// Pixel width of the captured image.
    public let width: Int
    /// Pixel height of the captured image.
    public let height: Int
    /// Number of bytes per pixel row (`width * 4`).
    public let bytesPerRow: Int
    /// The flattened RGBA pixel bytes (`bytesPerRow * height` in length).
    public let rgba: Data

    /// Creates a snapshot from already-flattened pixel data.
    public init(width: Int, height: Int, bytesPerRow: Int, rgba: Data) {
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.rgba = rgba
    }

    /// Renders `cgImage` into a premultiplied-last RGBA buffer, or returns
    /// `nil` when the image is empty or the bitmap context cannot be created.
    public init?(cgImage: CGImage) {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return nil }

        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var data = Data(count: bytesPerRow * height)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        let ok: Bool = data.withUnsafeMutableBytes { rawBuf in
            guard let base = rawBuf.baseAddress else { return false }
            guard let ctx = CGContext(
                data: base,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            ) else { return false }
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else { return nil }

        self.init(width: width, height: height, bytesPerRow: bytesPerRow, rgba: data)
    }

    /// Counts the pixels that changed by more than a small per-channel jitter
    /// threshold relative to `previous`. Returns `-1` when the two snapshots
    /// have mismatched dimensions and cannot be sensibly diffed (treat as a
    /// fresh snapshot).
    public func changedPixelCount(comparedTo previous: PanelSnapshotState) -> Int {
        // Any mismatch means we can't sensibly diff; treat as a fresh snapshot.
        guard previous.width == width,
              previous.height == height,
              previous.bytesPerRow == bytesPerRow else {
            return -1
        }

        let threshold = 8 // ignore tiny per-channel jitter
        var changed = 0

        previous.rgba.withUnsafeBytes { prevRaw in
            rgba.withUnsafeBytes { curRaw in
                guard let prev = prevRaw.bindMemory(to: UInt8.self).baseAddress,
                      let cur = curRaw.bindMemory(to: UInt8.self).baseAddress else {
                    return
                }

                let count = min(prevRaw.count, curRaw.count)
                var i = 0
                while i + 3 < count {
                    let dr = abs(Int(prev[i]) - Int(cur[i]))
                    let dg = abs(Int(prev[i + 1]) - Int(cur[i + 1]))
                    let db = abs(Int(prev[i + 2]) - Int(cur[i + 2]))
                    // Skip alpha channel at i+3.
                    if dr + dg + db > threshold {
                        changed += 1
                    }
                    i += 4
                }
            }
        }

        return changed
    }
}
