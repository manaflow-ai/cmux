public import AppKit
import Darwin

/// How ``NSWindow/snapshotImage()`` captured a window.
public nonisolated enum WindowSnapshotMethod: String, Sendable {
    /// The window server's composited image of the window (vibrancy,
    /// Liquid Glass and Metal layers as on screen).
    case composited
    /// AppKit drawing the frame view (``NSWindow/renderSnapshot()``).
    case appkit
}

extension NSWindow {
    /// Encodes an immutable capture as PNG and writes it atomically, off the
    /// main actor: AppKit capture stays on the main actor, the compression
    /// and the file write do not.
    public static func encodeSnapshotPNG(_ image: CGImage, to url: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            guard let data = image.pngData() else { throw CocoaError(.fileWriteUnknown) }
            try data.write(to: url, options: .atomic)
        }.value
    }

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
        compositedSnapshot(adding: [], includeChild: includeChild)
    }

    /// `compositedSnapshot(includeChild:)` with `extra` windows composited
    /// too: an app's panels over this window that are not its children (a
    /// panel opened with no key window to attach to).
    public func compositedSnapshot(adding extra: [NSWindow], includeChild: (NSWindow) -> Bool = { _ in true }) -> CGImage? {
        var children = visibleChildWindows.filter(includeChild)
        children += extra.filter { window in window !== self && !children.contains { $0 === window } }
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

    /// This app's windows the window server shows above this window and over its frame that
    /// are not the child windows a snapshot already composites (an open context menu, a hover
    /// card or popover not attached to it), as the window server composited them on a
    /// transparent image the size of this window, with their count; nil without one. A snapshot
    /// of the window then shows them as on screen. Menus are not in AppKit's window list, so
    /// the window server's list chooses (``ownWindows(above:pid:region:layer:skipping:ordinary:)``).
    public func floatingWindowsSnapshot() -> (image: CGImage, count: Int)? {
        guard windowNumber > 0, isOnActiveSpace, let primary = NSScreen.screens.first else { return nil }
        let above = (CGWindowListCopyWindowInfo([.optionOnScreenAboveWindow], CGWindowID(windowNumber)) as? [[String: Any]] ?? [])
            .compactMap(ListedWindow.init)
        let numbers = Self.ownWindows(above: above, pid: getpid(), region: Self.globalRect(of: frame, primaryHeight: primary.frame.maxY),
                                      layer: level.rawValue, skipping: Set(visibleChildWindows.map(\.windowNumber)),
                                      ordinary: Self.ordinaryWindowTrees(besides: self))
        guard !numbers.isEmpty, let image = Self.windowServerImage(ofNumbers: numbers, croppedTo: self),
              image.width > 0, image.height > 0, !Self.isBlank(image) else { return nil }
        return (image, numbers.count)
    }

    /// From `above` (the windows the window server shows above a window, topmost first), the
    /// numbers of this process's visible windows over `region` that a snapshot paints over it:
    /// not the `skipping` ones (its child windows, composited already), and not the ones that
    /// belong to another of the app's ordinary windows at the window's own `layer` (`ordinary`
    /// maps each window of such a tree to its ordinary window's layer), so a window behind
    /// another of the app's windows still comes out whole.
    nonisolated static func ownWindows(above: [ListedWindow], pid: pid_t, region: CGRect, layer: Int,
                                       skipping: Set<Int>, ordinary: [Int: Int]) -> [Int] {
        above.filter { window in
            window.pid == pid && window.alpha > 0 && !skipping.contains(window.number)
                && window.bounds.intersection(region).width > 0 && window.bounds.intersection(region).height > 0
                && ordinary[window.number] != layer
        }.map(\.number)
    }

    /// `frame` (AppKit screen coordinates) in global display coordinates: origin at the top
    /// left of the primary screen, which is `primaryHeight` points tall.
    nonisolated static func globalRect(of frame: NSRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height)
    }

    /// The app's ordinary (titled, non-panel, top-level) windows other than `window`, each with
    /// the windows that belong to it (child windows and attached sheets, with theirs), by
    /// number, to the ordinary window's level.
    private static func ordinaryWindowTrees(besides window: NSWindow) -> [Int: Int] {
        var result: [Int: Int] = [:]
        for root in NSApp.windows where root !== window && root.windowNumber > 0 && !(root is NSPanel)
            && root.styleMask.contains(.titled) && root.parent == nil && root.sheetParent == nil {
            var pending = [root]
            while let member = pending.popLast() {
                result[member.windowNumber] = root.level.rawValue
                pending += member.childWindows ?? []
                if let sheet = member.attachedSheet { pending.append(sheet) }
            }
        }
        return result
    }

    /// The visible child windows of this window and of its children, the
    /// ones a snapshot composites.
    public var visibleChildWindows: [NSWindow] {
        var result: [NSWindow] = []
        Self.appendVisibleChildWindows(of: self, into: &result)
        return result
    }

    /// Depth first, a child before its own children. A static function with inout state, not a
    /// capturing local function (Swift 6.3.3's SendNonSendable pass crashed now and then on those).
    private static func appendVisibleChildWindows(of window: NSWindow, into result: inout [NSWindow]) {
        for child in window.childWindows ?? [] where child.isVisible && child.windowNumber > 0 && child.alphaValue > 0 {
            result.append(child)
            appendVisibleChildWindows(of: child, into: &result)
        }
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
        windowServerImage(ofNumbers: frontToBack(windows.map(\.windowNumber)), croppedTo: frameWindow)
    }

    /// The windows `numbers` (topmost first) composited together, cropped to `frameWindow`'s frame.
    private static func windowServerImage(ofNumbers numbers: [Int], croppedTo frameWindow: NSWindow) -> CGImage? {
        typealias CreateImage = @convention(c) (CGRect, CFArray, UInt32) -> Unmanaged<CGImage>?
        guard frameWindow.windowNumber > 0, let primary = NSScreen.screens.first,
              let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImageFromArray") else { return nil }
        let create = unsafeBitCast(symbol, to: CreateImage.self)
        // The array holds CGWindowID values (not CFNumbers), topmost first.
        var ids: [UnsafeRawPointer?] = numbers.map { UnsafeRawPointer(bitPattern: UInt($0)) }
        guard let array = CFArrayCreate(nil, &ids, ids.count, nil) else { return nil }
        return create(globalRect(of: frameWindow.frame, primaryHeight: primary.frame.maxY), array, imageOptions)?.takeRetainedValue()
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
        image.isFullyTransparent
    }

    /// Captures the window image: composited when the window server gives one,
    /// else AppKit drawing. The capture itself must stay on the main actor
    /// because it reads AppKit state. Callers that already have an async
    /// boundary should encode the returned image away from the main actor.
    public func snapshotImage() throws -> (image: CGImage, method: WindowSnapshotMethod) {
        if let image = compositedSnapshot() {
            return (image, .composited)
        }
        if let image = renderSnapshot()?.cgImage {
            return (image, .appkit)
        }
        throw CocoaError(.fileWriteUnknown)
    }
}

/// A window as the window server lists it (`CGWindowListCopyWindowInfo`): menus included,
/// which AppKit's window list leaves out. `bounds` is in global display coordinates (origin at
/// the primary screen's top left).
nonisolated struct ListedWindow: Equatable, Sendable {
    let number: Int
    let pid: pid_t
    let layer: Int
    let bounds: CGRect
    let alpha: Double

    init(number: Int, pid: pid_t, layer: Int, bounds: CGRect, alpha: Double) {
        self.number = number
        self.pid = pid
        self.layer = layer
        self.bounds = bounds
        self.alpha = alpha
    }

    /// One entry of the window server's list; nil without a number, owner or bounds. An
    /// entry without an alpha is opaque.
    init?(_ info: [String: Any]) {
        guard let number = (info[kCGWindowNumber as String] as? NSNumber)?.intValue,
              let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
              let bounds = (info[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0 as CFDictionary) })
        else { return nil }
        self.init(number: number, pid: pid, layer: (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0, bounds: bounds,
                  alpha: (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1)
    }
}
