#if DEBUG
import AppKit
@testable import CmuxNextCloudUI
import Testing
import Vision

/// An Environment Secrets Playground view drawn offscreen in the light look, with its recognised text lines
/// (on-device Vision text recognition) in view points, origin top left. The rendered-view tests read it.
@MainActor
struct EnvRenderedPage: CustomStringConvertible {
    let bitmap: NSBitmapImageRep
    let lines: [(text: String, frame: CGRect)]
    let scale: CGFloat

    /// The whole playground (chrome and the model's direction) at `size`; the default is the window's size.
    init(_ model: EnvSecretsPlaygroundModel, size: CGSize = CGSize(width: 1180, height: 820)) throws {
        try self.init(view: EnvSecretsPlaygroundView(model: model, applyLook: {}), size: size)
    }

    /// Any playground view at `size`.
    init(view root: NSView, size: CGSize) throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        let light = try #require(NSAppearance(named: .aqua))
        window.appearance = light
        window.contentView = root
        root.widthAnchor.constraint(equalToConstant: size.width).isActive = true
        root.heightAnchor.constraint(equalToConstant: size.height).isActive = true
        window.setContentSize(size)
        root.layoutSubtreeIfNeeded()
        // A fixed 2x bitmap, not the screen's scale: a fleet Mac with a 1x (or no) screen would otherwise
        // round a 1.5-point line to 2 whole pixels and read every pixel measure differently.
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = size
        light.performAsCurrentDrawingAppearance { root.cacheDisplay(in: root.bounds, to: bitmap) }
        let image = try #require(bitmap.cgImage)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([request])
        self.bitmap = bitmap
        self.scale = CGFloat(bitmap.pixelsWide) / size.width
        self.lines = (request.results ?? []).compactMap { observation in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            let box = observation.boundingBox
            return (text, CGRect(x: box.minX * size.width, y: (1 - box.maxY) * size.height,
                                 width: box.width * size.width, height: box.height * size.height))
        }
    }

    /// The recognised lines, for a failed expectation's message.
    var description: String { lines.map(\.text).joined(separator: " | ") }

    /// Every recognised line joined by spaces.
    var text: String { lines.map(\.text).joined(separator: " ") }

    /// The recognised lines that end in an ellipsis: text cut off at the view's edge.
    var cutLines: [String] { lines.map(\.text).filter { $0.hasSuffix("…") || $0.hasSuffix("...") } }

    /// The frame of the line that reads exactly `text`.
    func line(_ text: String) -> CGRect? { lines.first { $0.text == text }?.frame }

    /// The frame of the first line that contains `text`.
    func line(containing text: String) -> CGRect? { lines.first { $0.text.contains(text) }?.frame }

    /// Strongly blue (accent) pixels in the 40 points left of `line`, from one line above it to its
    /// bottom: where a choice's radio is drawn.
    func accentPixels(leftOf line: CGRect) -> Int {
        let rows = Int((line.minY - line.height * 1.6) * scale)..<Int(line.maxY * scale)
        let columns = Int((line.minX - 40) * scale)..<Int(line.minX * scale)
        var count = 0
        for y in rows { for x in columns {
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
            if color.blueComponent > 0.75, color.redComponent < 0.35, color.greenComponent < 0.65 { count += 1 }
        } }
        return count
    }

    /// The width, in points, of the first run of accent-tinted pixels left of `line` on its middle row,
    /// within `reach` points: a card's highlighted border.
    func accentEdgeWidth(leftOf line: CGRect, reach: CGFloat = 30) -> CGFloat {
        let y = Int(line.midY * scale)
        var x = Int(line.minX * scale) - 1
        let stop = Int((line.minX - reach) * scale)
        var run = 0
        while x >= stop {
            let tinted = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB).map { $0.blueComponent - $0.redComponent > 0.2 } ?? false
            if tinted { run += 1 } else if run > 0 { break }
            x -= 1
        }
        return CGFloat(run) / scale
    }
}
#endif
