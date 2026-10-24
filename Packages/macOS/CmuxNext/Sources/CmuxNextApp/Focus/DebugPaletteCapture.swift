#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import CmuxNextDesign
import CmuxNextSettings
import Darwin

/// `debug.palette.capture {path}` (DEBUG builds): writes the open palette
/// panel to a PNG at `path` from this process (its own window, so no Screen
/// Recording grant and no focus change). Falls back to AppKit drawing the
/// panel on a flat backdrop when the window server gives no image of it (the
/// Cmd-Shift-P palette over an inactive app, cx-ytt0): drawing only the layer
/// tree left the views' content out, a flat gray image. Also answers the palette's `query` and its
/// `selected` row's title, so a real-key proof checks what Return will run before it presses it.
enum DebugPaletteCapture {
    static func capture(_ params: [String: JSONValue], services: AppServices) -> JSONValue {
        guard let path = params["path"]?.stringValue, !path.isEmpty else { return .object(["error": .string("path is required")]) }
        guard let panel = services.palette.visiblePanel else { return .object(["error": .string("the palette is not open")]) }
        guard case .object(var result) = capture(panel, to: path) else { return capture(panel, to: path) }
        let model = services.palette.model
        result["query"] = .string(model.query)
        result["selected"] = model.selectedItem.map { .string($0.title) } ?? .null
        return .object(result)
    }

    /// Writes `panel` to `path`; `windowImage` is the window server's image of a window, if any.
    static func capture(_ panel: NSWindow, to path: String, windowImage: (CGWindowID) -> CGImage? = windowImage) -> JSONValue {
        guard let view = panel.contentView else { return .object(["error": .string("the palette is not open")]) }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        // The composited window (glass included). A process may capture its
        // own windows without a Screen Recording grant.
        if let image = windowImage(CGWindowID(panel.windowNumber)), image.width > 1 {
            return write(image, to: path, source: "window")
        }
        guard let drawn = panel.renderSnapshot()?.cgImage else { return .object(["error": .string("no image")]) }
        let size = view.bounds.size
        let scale = panel.backingScaleFactor
        guard let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return .object(["error": .string("no bitmap context")]) }
        context.scaleBy(x: scale, y: scale)
        let dark = panel.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        context.setFillColor(dark ? CGColor(gray: 0.17, alpha: 1) : CGColor(gray: 0.93, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        context.draw(drawn, in: CGRect(origin: .zero, size: size))
        guard let image = context.makeImage() else { return .object(["error": .string("no image")]) }
        return write(image, to: path, source: "appkit")
    }

    /// The window-list capture, resolved at run time: the SDK marks it
    /// unavailable in favor of ScreenCaptureKit, which needs a Screen
    /// Recording grant even for the app's own windows. DEBUG evidence only.
    nonisolated static func windowImage(_ id: CGWindowID) -> CGImage? {
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
