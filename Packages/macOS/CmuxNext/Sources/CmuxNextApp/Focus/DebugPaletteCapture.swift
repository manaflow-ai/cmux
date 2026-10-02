#if DEBUG
import AppKit
import CmuxNextSettings

/// `debug.palette.capture {path}` (DEBUG builds): writes the open palette's
/// own layer tree to a PNG at `path`, drawn in this process, so design
/// evidence needs no Screen Recording grant and no window focus. The glass
/// backdrop does not draw this way; a flat backdrop in the window's
/// appearance stands in for it.
enum DebugPaletteCapture {
    static func capture(_ params: [String: JSONValue], services: AppServices) -> JSONValue {
        guard let path = params["path"]?.stringValue, !path.isEmpty else { return .object(["error": .string("path is required")]) }
        guard let panel = services.palette.visiblePanel, let view = panel.contentView, let layer = view.layer else {
            return .object(["error": .string("the palette is not open")])
        }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let size = view.bounds.size
        let scale = panel.backingScaleFactor
        guard let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return .object(["error": .string("no bitmap context")]) }
        context.scaleBy(x: scale, y: scale)
        let dark = panel.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        context.setFillColor(dark ? CGColor(gray: 0.17, alpha: 1) : CGColor(gray: 0.93, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        layer.render(in: context)
        guard let image = context.makeImage(),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else { return .object(["error": .string("no image")]) }
        do {
            try data.write(to: URL(fileURLWithPath: path))
        } catch {
            return .object(["error": .string(String(describing: error))])
        }
        return .object(["path": .string(path), "width": .number(Double(image.width)), "height": .number(Double(image.height))])
    }
}
#endif
