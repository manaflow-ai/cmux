#if DEBUG
import AppKit
import CmuxNextSettings
import Darwin

/// `debug.palette.capture {path}` (DEBUG builds): writes the open palette
/// panel to a PNG at `path` from this process (its own window, so no Screen
/// Recording grant and no focus change). Falls back to drawing the layer
/// tree on a flat backdrop when the window image is unavailable.
enum DebugPaletteCapture {
    static func capture(_ params: [String: JSONValue], services: AppServices) -> JSONValue {
        guard let path = params["path"]?.stringValue, !path.isEmpty else { return .object(["error": .string("path is required")]) }
        guard let panel = services.palette.visiblePanel, let view = panel.contentView, let layer = view.layer else {
            return .object(["error": .string("the palette is not open")])
        }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        // The composited window (glass included). A process may capture its
        // own windows without a Screen Recording grant.
        if let image = windowImage(CGWindowID(panel.windowNumber)), image.width > 1 {
            return write(image, to: path, source: "window")
        }
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
        guard let image = context.makeImage() else { return .object(["error": .string("no image")]) }
        return write(image, to: path, source: "layers")
    }

    /// The window-list capture, resolved at run time: the SDK marks it
    /// unavailable in favor of ScreenCaptureKit, which needs a Screen
    /// Recording grant even for the app's own windows. DEBUG evidence only.
    private static func windowImage(_ id: CGWindowID) -> CGImage? {
        typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        let capture = unsafeBitCast(symbol, to: Capture.self)
        let options = CGWindowListOption.optionIncludingWindow.rawValue
        let imageOptions = CGWindowImageOption([.boundsIgnoreFraming, .bestResolution]).rawValue
        return capture(.null, options, id, imageOptions)?.takeRetainedValue()
    }

    private static func write(_ image: CGImage, to path: String, source: String) -> JSONValue {
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            return .object(["error": .string("no image")])
        }
        do {
            try data.write(to: URL(fileURLWithPath: path))
        } catch {
            return .object(["error": .string(String(describing: error))])
        }
        return .object(["path": .string(path), "source": .string(source), "width": .number(Double(image.width)),
                        "height": .number(Double(image.height))])
    }
}
#endif
