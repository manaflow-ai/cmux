public import AppKit
import Darwin

/// How ``NSWindow/writeSnapshot(to:)`` captured a window.
public nonisolated enum WindowSnapshotMethod: String, Sendable {
    /// The window server's composited image of the window (vibrancy,
    /// Liquid Glass and Metal layers as on screen).
    case composited
    /// AppKit drawing the frame view (``NSWindow/renderSnapshot()``).
    case appkit
}

extension NSWindow {
    /// This window as AppKit draws it, without screen capture (no Screen
    /// Recording permission): the frame view (titlebar, traffic lights and
    /// content) rendered through `cacheDisplay(in:to:)` at the backing scale.
    ///
    /// It differs from the screen where content is not drawn by AppKit
    /// views or plain layers (plans/cmux-next/windows.md): Metal layers
    /// (Ghostty terminal surfaces, Chromium) render as their background,
    /// Liquid Glass and visual effect views render without the blur of what
    /// is behind the window, and child windows (Chromium page windows,
    /// panels) are not included.
    public func renderSnapshot() -> NSBitmapImageRep? {
        guard let frameView = contentView?.superview ?? contentView else { return nil }
        let bounds = frameView.bounds
        guard bounds.width > 0, bounds.height > 0,
              let rep = frameView.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        frameView.cacheDisplay(in: bounds, to: rep)
        return rep
    }

    /// This window and its visible child windows as the window server
    /// composited them, or nil (no window number, not on screen, or an
    /// all-transparent image). An app may read its own windows this way
    /// without the Screen Recording grant.
    ///
    /// Child windows are part of what the window shows: Chromium draws each
    /// page into a child window over its pane, and overlay panels sit above
    /// content. The ones `includeChild` accepts are composited in the window
    /// server's order, cropped to this window's frame. Windows of other apps
    /// are never included, so an occluded window still comes out whole.
    /// Without the Screen Recording grant the window server leaves out
    /// content another process draws (Chromium's GPU process renders the
    /// page), so a Chromium page window comes out as its background; the
    /// caller paints the engine's own page image over it.
    ///
    /// `CGWindowListCreateImage` and `CGWindowListCreateImageFromArray` are
    /// deprecated (ScreenCaptureKit replaces them, but needs the grant even
    /// for an app's own windows) and unavailable to Swift in the current
    /// SDK, so they are looked up at run time; a later macOS without the
    /// symbols falls back to AppKit drawing.
    public func compositedSnapshot(includeChild: (NSWindow) -> Bool = { _ in true }) -> CGImage? {
        let children = visibleChildWindows.filter(includeChild)
        let image = children.isEmpty
            ? Self.windowServerImage(of: windowNumber)
            : Self.windowServerImage(of: [self] + children, croppedTo: self)
        guard let image, image.width > 0, image.height > 0, !Self.isBlank(image) else { return nil }
        return image
    }

    /// Only the visible child windows `includeChild` accepts, as the window
    /// server composited them, on a transparent image the size of this
    /// window (cropped to its frame), or nil without one. Painted over a base
    /// image that has no child windows, or over page images.
    public func childWindowsSnapshot(includeChild: (NSWindow) -> Bool = { _ in true }) -> CGImage? {
        let children = visibleChildWindows.filter(includeChild)
        guard !children.isEmpty, let image = Self.windowServerImage(of: children, croppedTo: self),
              image.width > 0, image.height > 0, !Self.isBlank(image) else { return nil }
        return image
    }

    /// The visible child windows of this window and of its children, the
    /// ones a snapshot composites.
    public var visibleChildWindows: [NSWindow] {
        var result: [NSWindow] = []
        func visit(_ window: NSWindow) {
            for child in window.childWindows ?? [] where child.isVisible && child.windowNumber > 0 && child.alphaValue > 0 {
                result.append(child)
                visit(child)
            }
        }
        visit(self)
        return result
    }

    // kCGWindowImageBoundsIgnoreFraming | kCGWindowImageBestResolution.
    private static let imageOptions: UInt32 = (1 << 0) | (1 << 3)

    /// One window's image (`CGWindowListCreateImage`, kCGWindowListOptionIncludingWindow).
    private static func windowServerImage(of windowNumber: Int) -> CGImage? {
        typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard windowNumber > 0, let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else {
            return nil
        }
        let create = unsafeBitCast(symbol, to: CreateImage.self)
        return create(.null, 1 << 3, UInt32(windowNumber), imageOptions)?.takeRetainedValue()
    }

    /// `windows` composited together (`CGWindowListCreateImageFromArray`),
    /// cropped to `frameWindow`'s frame.
    private static func windowServerImage(of windows: [NSWindow], croppedTo frameWindow: NSWindow) -> CGImage? {
        typealias CreateImage = @convention(c) (CGRect, CFArray, UInt32) -> Unmanaged<CGImage>?
        guard frameWindow.windowNumber > 0, let primary = NSScreen.screens.first,
              let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImageFromArray") else { return nil }
        let create = unsafeBitCast(symbol, to: CreateImage.self)
        // The array holds CGWindowID values (not CFNumbers), topmost first.
        var ids: [UnsafeRawPointer?] = frontToBack(windows.map(\.windowNumber)).map { UnsafeRawPointer(bitPattern: UInt($0)) }
        guard let array = CFArrayCreate(nil, &ids, ids.count, nil) else { return nil }
        // Global display coordinates: origin at the primary screen's top left.
        let frame = frameWindow.frame
        let bounds = CGRect(x: frame.minX, y: primary.frame.maxY - frame.maxY, width: frame.width, height: frame.height)
        return create(bounds, array, imageOptions)?.takeRetainedValue()
    }

    /// `numbers` topmost first, as the window server orders them on screen.
    /// Windows it does not list on screen keep AppKit's order behind them
    /// (each child after its parent is above it, so reversed).
    private static func frontToBack(_ numbers: [Int]) -> [Int] {
        let wanted = Set(numbers)
        let onScreen = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? [])
            .compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.intValue }
            .filter { wanted.contains($0) }
        let listed = Set(onScreen)
        return onScreen + numbers.reversed().filter { !listed.contains($0) }
    }

    /// Whether every pixel of `image` is transparent (sampled at 64 x 64).
    static func isBlank(_ image: CGImage) -> Bool {
        let side = 64
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                          bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return true }
        return !stride(from: 3, to: pixels.count, by: 4).contains { pixels[$0] > 0 }
    }

    /// Writes the window as PNG to `url`: composited when the window server
    /// gives an image (``compositedSnapshot()``), else AppKit drawing
    /// (``renderSnapshot()``). Returns the pixel size and the method used.
    public func writeSnapshot(to url: URL) throws -> (size: CGSize, method: WindowSnapshotMethod) {
        let rep: NSBitmapImageRep
        let method: WindowSnapshotMethod
        if let image = compositedSnapshot() {
            rep = NSBitmapImageRep(cgImage: image)
            method = .composited
        } else if let drawn = renderSnapshot() {
            rep = drawn
            method = .appkit
        } else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard let data = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: url, options: .atomic)
        return (CGSize(width: rep.pixelsWide, height: rep.pixelsHigh), method)
    }
}
