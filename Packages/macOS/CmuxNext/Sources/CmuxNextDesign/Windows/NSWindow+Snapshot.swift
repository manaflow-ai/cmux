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
        compositedCapturePlan(adding: extra, includeChild: includeChild).flatMap(Self.capture)
    }

    /// What ``compositedSnapshot(adding:includeChild:)`` captures, read from AppKit on the main
    /// actor: the window numbers and the frame. ``capture(_:)`` runs the window server calls,
    /// which need no AppKit state, on any thread (an agent's screenshot off the main thread).
    public func compositedCapturePlan(adding extra: [NSWindow] = [], includeChild: (NSWindow) -> Bool = { _ in true }) -> WindowCapturePlan? {
        guard windowNumber > 0 else { return nil }
        var children = visibleChildWindows.filter(includeChild)
        children += extra.filter { window in window !== self && !children.contains { $0 === window } }
        if children.isEmpty { return WindowCapturePlan(numbers: [windowNumber], frame: nil) }
        guard let primary = NSScreen.screens.first else { return nil }
        return WindowCapturePlan(numbers: ([self] + children).map(\.windowNumber),
                                 frame: Self.globalRect(of: frame, primaryHeight: primary.frame.maxY))
    }

    /// The window server's image for `plan`, nil when it gives none or a blank one. Any thread.
    public nonisolated static func capture(_ plan: WindowCapturePlan) -> CGImage? {
        let image: CGImage?
        if let frame = plan.frame {
            image = windowServerImage(ofNumbers: frontToBack(plan.numbers), rect: frame)
        } else {
            image = plan.numbers.first.flatMap(windowServerImage(of:))
        }
        guard let image, image.width > 0, image.height > 0, !image.isFullyTransparent else { return nil }
        return image
    }

    /// Only the visible child windows `includeChild` accepts, as the window
    /// server composited them, on a transparent image the size of this
    /// window (cropped to its frame), or nil without one. Painted over a base
    /// image that has no child windows, or over page images.
    public func childWindowsSnapshot(includeChild: (NSWindow) -> Bool = { _ in true }) -> CGImage? {
        childWindowsCapturePlan(includeChild: includeChild).flatMap(Self.capture)
    }

    /// ``childWindowsSnapshot(includeChild:)`` with the window server calls (the composite of
    /// the child windows and the blank check) off the main actor; main reads only the window
    /// numbers and the frame. For an agent's screenshot, which must not stall the person's typing.
    public func childWindowsImage(includeChild: (NSWindow) -> Bool = { _ in true }) async -> CGImage? {
        guard let plan = childWindowsCapturePlan(includeChild: includeChild) else { return nil }
        return await Self.capturedOffMain(plan)
    }

    /// What ``childWindowsSnapshot(includeChild:)`` captures: the accepted visible child
    /// windows, cropped to this window's frame (global display coordinates).
    func childWindowsCapturePlan(includeChild: (NSWindow) -> Bool) -> WindowCapturePlan? {
        let children = visibleChildWindows.filter(includeChild)
        guard !children.isEmpty, windowNumber > 0, let primary = NSScreen.screens.first else { return nil }
        return WindowCapturePlan(numbers: children.map(\.windowNumber), frame: Self.globalRect(of: frame, primaryHeight: primary.frame.maxY))
    }

    /// ``capture(_:)`` off the main actor.
    @concurrent
    nonisolated static func capturedOffMain(_ plan: WindowCapturePlan) async -> CGImage? {
        capture(plan)
    }

    /// This app's windows the window server shows above this window and over its frame that
    /// are not the child windows a snapshot already composites (an open context menu, a hover
    /// card or popover not attached to it), as the window server composited them on a
    /// transparent image the size of this window, with their count; nil without one. A snapshot
    /// of the window then shows them as on screen. Menus are not in AppKit's window list, so
    /// the window server's list chooses (``ownWindows(above:pid:region:layer:skipping:ordinary:)``).
    public func floatingWindowsSnapshot() -> (image: CGImage, count: Int)? {
        floatingWindowsCapturePlan().flatMap(Self.capture)
    }

    /// ``floatingWindowsSnapshot()`` with the window server calls (its window list, the
    /// composite and the blank check) off the main actor; main reads only this window's number,
    /// frame and level and the app's own window trees.
    public func floatingWindowsImage() async -> (image: CGImage, count: Int)? {
        guard let plan = floatingWindowsCapturePlan() else { return nil }
        return await Self.capturedOffMain(plan)
    }

    /// What ``floatingWindowsSnapshot()`` captures, read from AppKit on the main actor.
    func floatingWindowsCapturePlan() -> FloatingWindowsCapturePlan? {
        guard windowNumber > 0, isOnActiveSpace, let primary = NSScreen.screens.first else { return nil }
        return FloatingWindowsCapturePlan(window: windowNumber, pid: getpid(),
                                          region: Self.globalRect(of: frame, primaryHeight: primary.frame.maxY), layer: level.rawValue,
                                          // Capture backdrops are never overlays: a snapshot composites only
                                          // its own window's, behind it (another window's screen-sized
                                          // backdrop in front would cover this window).
                                          skipping: Set(visibleChildWindows.map(\.windowNumber)).union(Self.captureBackdropNumbers),
                                          ordinary: Self.ordinaryWindowTrees(besides: self))
    }

    /// The numbers of the windows `plan` finds above its window, topmost first. Any thread.
    nonisolated static func floatingWindowNumbers(in plan: FloatingWindowsCapturePlan) -> [Int] {
        let above = (CGWindowListCopyWindowInfo([.optionOnScreenAboveWindow], CGWindowID(plan.window)) as? [[String: Any]] ?? [])
            .compactMap(ListedWindow.init)
        return ownWindows(above: above, pid: plan.pid, region: plan.region, layer: plan.layer, skipping: plan.skipping,
                          ordinary: plan.ordinary)
    }

    /// The window server's image of the windows `plan` finds above its window, with their
    /// count; nil without one or when it is blank. Any thread.
    nonisolated static func capture(_ plan: FloatingWindowsCapturePlan) -> (image: CGImage, count: Int)? {
        let numbers = floatingWindowNumbers(in: plan)
        guard !numbers.isEmpty, let image = windowServerImage(ofNumbers: numbers, rect: plan.region),
              image.width > 0, image.height > 0, !image.isFullyTransparent else { return nil }
        return (image, numbers.count)
    }

    /// The floating-window capture of `plan` off the main actor.
    @concurrent
    nonisolated static func capturedOffMain(_ plan: FloatingWindowsCapturePlan) async -> (image: CGImage, count: Int)? {
        capture(plan)
    }

    /// The numbers of the windows ``floatingWindowsSnapshot()`` paints, topmost first.
    private func floatingWindowNumbers() -> [Int] {
        floatingWindowsCapturePlan().map { Self.floatingWindowNumbers(in: $0) } ?? []
    }

    /// This window, every visible child window and the app's windows over it
    /// (``floatingWindowsSnapshot()``: an open menu, a card or popover that is not its child)
    /// composited together by the window server and cropped to the window's frame, with how many
    /// of those other windows it includes; nil without an image (not on screen, or all
    /// transparent). Composited together, a glass or vibrancy panel blurs the window under it, as
    /// on screen; composited alone (``childWindowsSnapshot(includeChild:)``) it blurs nothing and
    /// comes out grey. Windows of other apps are never included.
    public func compositedSnapshotWithOverlays() -> (image: CGImage, floating: Int)? {
        guard windowNumber > 0 else { return nil }
        let floating = floatingWindowNumbers()
        let children = visibleChildWindows.map(\.windowNumber)
        // A capture backdrop (``captureBackdrop``) goes behind everything, so the window's
        // translucency and glass show it as on screen.
        let backdrop = captureBackdropNumber
        let image: CGImage?
        if children.isEmpty && floating.isEmpty && backdrop == nil {
            image = Self.windowServerImage(of: windowNumber)
        } else {
            guard let primary = NSScreen.screens.first else { return nil }
            let front = Self.frontToBack([windowNumber] + children + floating)
            image = Self.windowServerImage(ofNumbers: Self.compositeOrder(front: front, backdrop: backdrop),
                                           rect: Self.globalRect(of: frame, primaryHeight: primary.frame.maxY))
        }
        guard let image, image.width > 0, image.height > 0, !image.isFullyTransparent else { return nil }
        return (image, floating.count)
    }

    /// The overlays of `composite` (this window's ``compositedSnapshotWithOverlays()``): the
    /// visible child windows `includeChild` accepts and the app's windows over it, transparent
    /// elsewhere (``masked(_:by:)``). Nil without any. A page image painted over the composite
    /// covers the popovers and menus over its page; this, painted over the page image, gives
    /// them back, with the window's blur under them.
    public func overlays(cutFrom composite: CGImage, includeChild: (NSWindow) -> Bool) -> CGImage? {
        let numbers = visibleChildWindows.filter(includeChild).map(\.windowNumber) + floatingWindowNumbers()
        guard !numbers.isEmpty, windowNumber > 0, let primary = NSScreen.screens.first,
              let coverage = Self.windowServerImage(ofNumbers: Self.frontToBack(numbers),
                                                    rect: Self.globalRect(of: frame, primaryHeight: primary.frame.maxY)),
              coverage.width > 0, coverage.height > 0, !coverage.isFullyTransparent else { return nil }
        return Self.masked(composite, by: coverage)
    }

    /// At `image`'s size: `image` (the window's composite) where `coverage` (the overlays alone) is
    /// opaque, so glass there keeps the blur of the window under it; `coverage` itself where it is
    /// translucent (a shadow, a fade, an antialiased edge), since the composite there already
    /// blends the overlay with the window, and painted over a page it would fade the overlay twice;
    /// transparent elsewhere.
    nonisolated static func masked(_ image: CGImage, by coverage: CGImage) -> CGImage? {
        let width = image.width, height = image.height
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        func pixels(_ source: CGImage) -> [UInt8]? {
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: width * 4, space: space, bitmapInfo: info) else { return false }
                context.interpolationQuality = .high
                context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            return drawn ? bytes : nil
        }
        guard var result = pixels(coverage), let composite = pixels(image) else { return nil }
        result.withUnsafeMutableBufferPointer { out in
            composite.withUnsafeBufferPointer { under in
                for index in stride(from: 0, to: out.count, by: 4) where out[index + 3] == 255 {
                    out[index] = under[index]
                    out[index + 1] = under[index + 1]
                    out[index + 2] = under[index + 2]
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(result) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)
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
    private nonisolated static let imageOptions: UInt32 = (1 << 0) | (1 << 3)

    /// One window's image (`CGWindowListCreateImage`, kCGWindowListOptionIncludingWindow).
    private nonisolated static func windowServerImage(of windowNumber: Int) -> CGImage? {
        typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard windowNumber > 0, let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else {
            return nil
        }
        let create = unsafeBitCast(symbol, to: CreateImage.self)
        return create(.null, 1 << 3, UInt32(windowNumber), imageOptions)?.takeRetainedValue()
    }

    /// The windows `numbers` (topmost first) composited together, cropped to `rect` (global
    /// display coordinates). Any thread.
    private nonisolated static func windowServerImage(ofNumbers numbers: [Int], rect: CGRect) -> CGImage? {
        typealias CreateImage = @convention(c) (CGRect, CFArray, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImageFromArray") else { return nil }
        let create = unsafeBitCast(symbol, to: CreateImage.self)
        // The array holds CGWindowID values (not CFNumbers), topmost first.
        var ids: [UnsafeRawPointer?] = numbers.map { UnsafeRawPointer(bitPattern: UInt($0)) }
        guard let array = CFArrayCreate(nil, &ids, ids.count, nil) else { return nil }
        return create(rect, array, imageOptions)?.takeRetainedValue()
    }

    /// `numbers` topmost first, as the window server orders them on screen.
    /// Windows it does not list on screen keep AppKit's order behind them
    /// (each child after its parent is above it, so reversed).
    private nonisolated static func frontToBack(_ numbers: [Int]) -> [Int] {
        let onScreen = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? [])
            .compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.intValue }
        return frontToBack(numbers, onScreen: onScreen)
    }

    /// `numbers` in the order of `onScreen` (the window server's on-screen list, topmost first),
    /// then the ones it does not list, last of `numbers` first; each number once.
    nonisolated static func frontToBack(_ numbers: [Int], onScreen: [Int]) -> [Int] {
        let wanted = Set(numbers)
        var seen = Set<Int>()
        let listed = onScreen.filter { wanted.contains($0) && seen.insert($0).inserted }
        return listed + numbers.reversed().filter { seen.insert($0).inserted }
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
