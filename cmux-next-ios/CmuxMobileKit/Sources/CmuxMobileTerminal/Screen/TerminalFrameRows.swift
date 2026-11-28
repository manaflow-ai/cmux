#if os(iOS)
import CoreGraphics
import SwiftUI
import UIKit

/// Where a cached page's rows are in its still, so the still is laid out for the page as it
/// is now, not as it was captured.
///
/// Leo, 2026-11-24: "the served cached thing included the gap induced by my built-in keyboard,
/// and i couldnt interact with it stil." A still is the whole page: the terminal's background,
/// with the rows only between the top bar and the composer as they were then
/// (`TerminalStillPlan.rowsClip`). Captured with the keyboard up, its rows end mid screen; drawn
/// over the page top-anchored and full height, it showed a blank band below them and covered
/// the composer and key row. The page now draws only the still's rows: their last line on the
/// composer as it rests now (keyboard up or down), nothing over the composer.
public struct TerminalFrameRows: Equatable, Sendable {
    /// The last row with anything drawn, as a fraction of the still's height (its bottom edge).
    public var contentBottom: CGFloat

    public init(contentBottom: CGFloat) {
        self.contentBottom = contentBottom
    }

    /// Reads the still: the lowest pixel row that differs from the background (the still's
    /// bottom row, always below the rows clip). Nil: nothing drawn (a blank page).
    public static func measure(_ image: CGImage) -> TerminalFrameRows? {
        // Sampled small: a glyph's stroke still shifts its row's average off the background.
        let width = min(image.width, 256)
        let height = max(1, Int((CGFloat(image.height) * CGFloat(width) / CGFloat(max(1, image.width))).rounded()))
        guard width > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        // Memory row 0 is the image's top (a bitmap context's rows run top down in memory).
        let rowBytes = width * 4
        return measure(pixels: pixels, width: width, height: height, rowBytes: rowBytes)
    }

    /// The scan itself, on RGBA bytes whose first row is the top.
    static func measure(pixels: UnsafePointer<UInt8>, width: Int, height: Int, rowBytes: Int) -> TerminalFrameRows? {
        guard width > 0, height > 1 else { return nil }
        let base = (height - 1) * rowBytes + (width / 2) * 4
        let background = (Int(pixels[base]), Int(pixels[base + 1]), Int(pixels[base + 2]))
        // JPEG noise stays well under this; antialiased text at 256 px does not.
        let threshold = 28
        for row in stride(from: height - 1, through: 0, by: -1) {
            let start = row * rowBytes
            for column in 0..<width {
                let p = start + column * 4
                let d = abs(Int(pixels[p]) - background.0) + abs(Int(pixels[p + 1]) - background.1) + abs(Int(pixels[p + 2]) - background.2)
                if d > threshold {
                    return TerminalFrameRows(contentBottom: CGFloat(row + 1) / CGFloat(height))
                }
            }
        }
        return nil
    }
}

/// Where a still's rows go on the page now (``TerminalFrameRows``): the still is drawn at the
/// page's width, moved so its last row rests on the composer's top as it is now, and clipped to
/// the rows area (never over the composer or the key row).
public struct TerminalFramePlacement: Equatable, Sendable {
    /// The still's top on the page.
    public var imageTop: CGFloat
    /// The still's drawn height.
    public var imageHeight: CGFloat
    /// Drawn above this only: the rows area's bottom (the composer's top, as it rests now).
    public var clipBottom: CGFloat

    public static func make(pageWidth: CGFloat, imageSize: CGSize, rows: TerminalFrameRows?, rowsBottom: CGFloat) -> TerminalFramePlacement {
        let height = pageWidth * imageSize.height / max(1, imageSize.width)
        guard let rows else {
            // A still with nothing measured stays where it was taken, clipped above the composer.
            return TerminalFramePlacement(imageTop: 0, imageHeight: height, clipBottom: rowsBottom)
        }
        return TerminalFramePlacement(imageTop: rowsBottom - rows.contentBottom * height, imageHeight: height, clipBottom: rowsBottom)
    }
}

/// The last stills measured (``TerminalFrameRows``), by identity: a still handed from one host
/// to the next (a reconnect, the warm set, the frame keep) is measured once.
@MainActor
enum TerminalFrameRowsMemo {
    private static var entries: [(image: WeakImage, rows: TerminalFrameRows?)] = []

    private struct WeakImage {
        weak var image: UIImage?
    }

    static func rows(for image: UIImage) -> TerminalFrameRows? {
        entries.removeAll { $0.image.image == nil }
        if let hit = entries.first(where: { $0.image.image === image }) { return hit.rows }
        let rows = image.cgImage.flatMap { TerminalFrameRows.measure($0) }
        entries.append((WeakImage(image: image), rows))
        if entries.count > 8 { entries.removeFirst(entries.count - 8) }
        return rows
    }
}

/// The software keyboard's height over the bottom of the screen (0: down), for views that lay
/// out against the composer without the keyboard safe area (TabsKit ignores it for its pages).
@MainActor
@Observable
public final class TerminalKeyboardHeight {
    public static let shared = TerminalKeyboardHeight()

    public private(set) var height: CGFloat = 0
    @ObservationIgnored private var tokens: [NSObjectProtocol] = []

    private init() {
        let center = NotificationCenter.default
        tokens.append(center.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main) { note in
            let end = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
            MainActor.assumeIsolated { TerminalKeyboardHeight.shared.update(end) }
        })
        tokens.append(center.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { TerminalKeyboardHeight.shared.update(nil) }
        })
    }

    private func update(_ end: CGRect?) {
        let screen = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen }.first?.bounds
            ?? CGRect(x: 0, y: 0, width: 0, height: 0)
        let next = end.map { max(0, screen.maxY - $0.minY) } ?? 0
        if next != height { height = next }
    }
}
#endif
