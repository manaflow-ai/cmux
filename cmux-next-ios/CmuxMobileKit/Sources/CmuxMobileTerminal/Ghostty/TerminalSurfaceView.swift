#if os(iOS)
import CmuxMobileDesign
import CoreImage
import Foundation
import GameController
import GhosttyNextKit
import IOSurface
import UIKit
import UniformTypeIdentifiers

/// One Ghostty surface in mirror mode (adapted from CmuxiOSTerminal's
/// GhosttyTerminalView). The phone owns no PTY: session output arrives through
/// `feed`, and everything typed leaves through `onInput`, encoded by Ghostty.
///
/// The screen owns the viewport: it sizes the surface to a whole number of
/// rows plus a margin, asks Ghostty for a viewport row with `scroll(toRow:)`,
/// and places the surface in a scroll view only when a frame for that row is
/// presented (`onPresent`), so the rows on screen and the surface position
/// always change in the same Core Animation transaction. Ghostty rebuilds
/// cells on its renderer thread, so a frame for a new viewport arrives a few
/// milliseconds after the request; the margin keeps the visible rows covered
/// by the previous frame until then.
@MainActor
final class TerminalSurfaceView: UIView {
    var onInput: ((Data) -> Void)?
    /// The person typed, pressed a key or pasted (before the bytes go out).
    var onUserInput: (() -> Void)?
    var onEvent: ((TerminalSurfaceEvent) -> Void)?
    /// The surface became first responder (direct typing) or resigned.
    var onFocusChange: ((Bool) -> Void)?
    /// The sticky modifier state changed (the key bar shows it).
    var onStickyChange: ((TerminalStickyModifiers) -> Void)?

    private(set) var surface: ghostty_surface_t?
    var input = TerminalInputRouter() {
        didSet { if input.sticky != oldValue.sticky { onStickyChange?(input.sticky) } }
    }
    weak var inputDelegate: (any UITextInputDelegate)?
    var handledPresses: [ObjectIdentifier: [TerminalInputAction]] = [:]
    var keyboardKind: UIKeyboardType = .asciiCapable

    private var app: CmuxMobileGhosttyApp?
    private let outputQueue = DispatchQueue(label: "cmuxMobile.terminal.output", qos: .userInteractive)
    private var inputBox: InputBox?
    private var pendingOutput: [Data] = []
    private(set) var draws = 0
    /// The last row given to `scroll(toRow:)`.
    private var pinnedRow: Int?
    /// The font size the surface was built with or last set to (Settings → Terminal).
    private var fontSize = CmuxMobilePreferences.terminalFontSize()
    private var defaultsObserver: (any NSObjectProtocol)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = CmuxMobileGhosttyApp.background
        isOpaque = true
        isAccessibilityElement = true
        accessibilityLabel = "Terminal"
        accessibilityTraits = .allowsDirectInteraction
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    isolated deinit {
        if let commitObserver { CFRunLoopObserverInvalidate(commitObserver) }
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
        for observer in appStateObservers { NotificationCenter.default.removeObserver(observer) }
        guard let surface else { return }
        let ref = SurfaceRef(surface)
        let box = inputBox.map(Retained.init)
        outputQueue.async {
            DispatchQueue.main.async {
                ghostty_surface_free(ref.surface)
                _ = box
            }
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateOcclusion()
        guard window != nil else { return }
        guard surface != nil else { return createSurface() }
        // Back in a window: its screen's scale may differ from the one the
        // size was last given at.
        syncSize()
    }

    private func createSurface() {
        guard let app = try? CmuxMobileGhosttyApp.shared() else { return }
        self.app = app
        let box = InputBox()
        box.deliver = { [weak self] data in self?.onInput?(data) }
        box.view = self
        inputBox = box
        var config = ghostty_surface_config_new()
        config.platform_tag = GHOSTTY_PLATFORM_IOS
        config.platform = ghostty_platform_u(ios: ghostty_platform_ios_s(uiview: Unmanaged.passUnretained(self).toOpaque()))
        config.userdata = Unmanaged.passUnretained(box).toOpaque()
        config.scale_factor = Double(renderScale)
        fontSize = CmuxMobilePreferences.terminalFontSize()
        config.font_size = Float(fontSize)
        config.io_mode = GHOSTTY_SURFACE_IO_MANUAL_MIRROR
        config.io_write_userdata = Unmanaged.passUnretained(box).toOpaque()
        config.io_write_cb = { userdata, bytes, length in
            guard let userdata, let bytes, length > 0 else { return }
            let data = Data(bytes: bytes, count: Int(length))
            let box = Unmanaged<InputBox>.fromOpaque(userdata).takeUnretainedValue()
            if Thread.isMainThread {
                MainActor.assumeIsolated { box.deliver?(data) }
            } else {
                DispatchQueue.main.async { MainActor.assumeIsolated { box.deliver?(data) } }
            }
        }
        surface = ghostty_surface_new(app.app, &config)
        guard let surface else { return }
        // Ghostty draws only while the surface can be seen (`updateOcclusion`).
        observeAppState()
        updateOcclusion()
        ghostty_surface_set_focus(surface, true)
        syncSize()
        let queued = pendingOutput
        pendingOutput.removeAll()
        for data in queued { feed(data) }
        onEvent?(.cellSize)
        observePresents()
        observeFontSize()
    }

    // MARK: Occlusion

    /// The app is in the background: nothing on screen is seen.
    private var appInBackground = UIApplication.shared.applicationState == .background
    private var appStateObservers: [any NSObjectProtocol] = []
    /// The last value given to `ghostty_surface_set_occlusion` (true = draws).
    private(set) var drawsFrames: Bool?

    /// Ghostty draws only while this surface can be seen: in a window, with
    /// the app in the foreground (the Mac app's `WindowDrawPolicy` pauses
    /// hidden surfaces the same way). A paused surface still parses output
    /// and its layer keeps the last frame (the card snapshot reads it);
    /// shown again, Ghostty draws its current content. A warm tab behind
    /// another and every terminal in the background drew a frame per output
    /// batch before (renderer audit 2026-10-26).
    private func updateOcclusion() {
        guard let surface else { return }
        let visible = window != nil && !appInBackground
        guard visible != drawsFrames else { return }
        drawsFrames = visible
        ghostty_surface_set_occlusion(surface, visible)
    }

    private func observeAppState() {
        guard appStateObservers.isEmpty else { return }
        let center = NotificationCenter.default
        let set: @MainActor (Bool) -> Void = { [weak self] background in
            guard let self else { return }
            self.appInBackground = background
            self.updateOcclusion()
        }
        appStateObservers = [
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { set(true) }
            },
            center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { set(false) }
            },
        ]
    }

    /// Settings → Terminal → Font size applies to open terminals at once:
    /// Ghostty re-measures its cells and reports the new cell size, and the
    /// screen re-fits the grid from it.
    private func observeFontSize() {
        guard defaultsObserver == nil else { return }
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyFontSize() }
        }
    }

    private func applyFontSize() {
        let size = CmuxMobilePreferences.terminalFontSize()
        guard let surface, size != fontSize else { return }
        fontSize = size
        viewportEpoch += 1
        let action = "set_font_size:\(size)"
        _ = action.withCString { ghostty_surface_binding_action(surface, $0, UInt(strlen($0))) }
        ghostty_surface_refresh(surface)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        syncSize()
        observePresents()
    }

    private var lastPixelSize: (UInt32, UInt32) = (0, 0)
    private var lastScale: CGFloat = 0
    /// The scale the surface draws at: its window's screen, else the last
    /// one it had in a window, so a page out of its window keeps the scale
    /// its cells were measured at (a 2x device never falls back to 3x).
    var renderScale: CGFloat {
        if let scale = window?.screen.scale { return scale }
        if lastScale > 0 { return lastScale }
        return UIScreen.main.scale
    }

    /// Bumped by everything here that can move Ghostty's viewport (a scroll
    /// binding, a resize, a font size): a frame after a bump may show
    /// another viewport, so its placement is read from its pixels again.
    private(set) var viewportEpoch = 0

    /// Tells Ghostty the view's size, with or without a window. A page out
    /// of its window (the workspace list on top, a warm tab behind another)
    /// still parses output: a frame change there must reach Ghostty at once,
    /// or the bytes are parsed at the old grid (the Mac's 120 columns parsed
    /// at the phone's 49 wrapped every row of htop, PR #24650 live rig).
    private func syncSize() {
        guard let surface else { return }
        let scale = renderScale
        let size = (UInt32(bounds.width * scale), UInt32(bounds.height * scale))
        guard size.0 > 0, size.1 > 0, size != lastPixelSize || scale != lastScale else { return }
        lastPixelSize = size
        viewportEpoch += 1
        if scale != lastScale { ghostty_surface_set_content_scale(surface, scale, scale) }
        lastScale = scale
        ghostty_surface_set_size(surface, size.0, size.1)
        if let pinnedRow { scrollViewport(pinnedRow) }
        // Out of a window nothing shows: the next frame in one draws it.
        if window != nil { drawNow() }
    }

    #if DEBUG
    /// DEBUG (termqa round 8): reads one row by each Ghostty point tag, to
    /// pin down which numbering each one uses.
    func debugReadRow(tag: ghostty_point_tag_e, y: Int, rectangle: Bool = false) -> String? {
        guard let surface else { return nil }
        let columns = max(1, grid.columns)
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(tag: tag, coord: GHOSTTY_POINT_COORD_EXACT, x: 0, y: UInt32(max(0, y))),
            bottom_right: ghostty_point_s(tag: tag, coord: GHOSTTY_POINT_COORD_EXACT, x: UInt32(columns - 1), y: UInt32(max(0, y))),
            rectangle: rectangle
        )
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let pointer = text.text, text.text_len > 0 else { return "" }
        return String(decoding: UnsafeRawBufferPointer(start: pointer, count: Int(text.text_len)), as: UTF8.self)
    }

    /// DEBUG: the whole screen as a rectangle selection (one line per row?).
    func debugScreenRectangle() -> String? {
        guard let surface else { return nil }
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: true
        )
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let pointer = text.text, text.text_len > 0 else { return "" }
        return String(decoding: UnsafeRawBufferPointer(start: pointer, count: Int(text.text_len)), as: UTF8.self)
    }
    #endif

    // MARK: Metrics

    /// Cell size in points (zero before the surface exists).
    var cellSize: CGSize {
        guard let surface else { return .zero }
        var metrics = ghostty_surface_grid_metrics_s()
        if ghostty_surface_grid_metrics(surface, &metrics), metrics.cell_height > 0 {
            return CGSize(width: metrics.cell_width, height: metrics.cell_height)
        }
        let size = ghostty_surface_size(surface)
        let scale = renderScale
        return CGSize(width: CGFloat(size.cell_width_px) / scale, height: CGFloat(size.cell_height_px) / scale)
    }

    /// The whole screen (scrollback and active area) as text. Ghostty joins
    /// the rows it soft-wrapped, so a long path reads as one line. Takes the
    /// surface lock: call it on demand (Files and Links), never per frame.
    func screenText() -> String? {
        guard let surface else { return nil }
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: false
        )
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let pointer = text.text, text.text_len > 0 else { return "" }
        return String(decoding: UnsafeRawBufferPointer(start: pointer, count: Int(text.text_len)), as: UTF8.self)
    }

    /// Every row of the screen, numbered like the scrollbar, with its soft
    /// wraps (`TerminalScreenRows`): a rectangle read (one line per row) and
    /// the plain read (wrapped rows joined). Whole-screen reads are not
    /// clamped to the grid like an exact point's y. Takes the surface lock
    /// twice: on demand only (a Copy).
    func screenRows() -> TerminalScreenRows? {
        guard let surface else { return nil }
        func read(rectangle: Bool) -> String? {
            let selection = ghostty_selection_s(
                top_left: ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
                bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
                rectangle: rectangle
            )
            var text = ghostty_text_s()
            guard ghostty_surface_read_text(surface, selection, &text) else { return nil }
            defer { ghostty_surface_free_text(surface, &text) }
            guard let pointer = text.text, text.text_len > 0 else { return "" }
            return String(decoding: UnsafeRawBufferPointer(start: pointer, count: Int(text.text_len)), as: UTF8.self)
        }
        guard let rectangle = read(rectangle: true), let logical = read(rectangle: false) else { return nil }
        return TerminalScreenRows(rectangle: rectangle, logical: logical, columns: grid.columns)
    }

    /// The grid's padding inside the surface (points): where cell (0, 0) starts.
    var gridPadding: CGPoint {
        guard let surface else { return .zero }
        var metrics = ghostty_surface_grid_metrics_s()
        guard ghostty_surface_grid_metrics(surface, &metrics) else { return .zero }
        return CGPoint(x: metrics.padding_left, y: metrics.padding_top)
    }

    /// Plain text from `start` to `end` in viewport rows (0 = the top row of
    /// Ghostty's viewport, the surface's first row), inclusive, for a
    /// selection's Copy. Viewport rows, not screen rows: a screen point's y
    /// does not count the rows the scrollbar's total does (round 7: screen y
    /// 109 was absolute row 305). Takes the surface lock: on demand only.
    func viewportText(from start: TerminalCellPoint, to end: TerminalCellPoint) -> String? {
        guard let surface else { return nil }
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT,
                                      x: UInt32(max(0, start.column)), y: UInt32(max(0, start.row))),
            bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT,
                                          x: UInt32(max(0, end.column)), y: UInt32(max(0, end.row))),
            rectangle: false
        )
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let pointer = text.text, text.text_len > 0 else { return "" }
        return String(decoding: UnsafeRawBufferPointer(start: pointer, count: Int(text.text_len)), as: UTF8.self)
    }

    /// Plain text of the active area (the bottom `grid.rows` rows; the
    /// alternate screen in a TUI). Takes the surface lock: on demand only.
    func activeAreaText() -> String? {
        guard surface != nil, grid.rows > 0 else { return nil }
        return readRows(tag: GHOSTTY_POINT_ACTIVE, from: 0, through: grid.rows - 1)
    }

    /// The rows numbered the way the scrollbar counts them, at this moment
    /// (`TerminalRowSpace`): the scrollbar's total and the viewport's top.
    func rowReader(totalRows: Int, viewportTop: Int) -> TerminalRowReader {
        TerminalRowReader(space: TerminalRowSpace(totalRows: totalRows, gridRows: grid.rows, viewportTop: viewportTop), source: self)
    }

    /// Rows `first...last` of one Ghostty numbering, in one read. Ghostty
    /// clamps y to the grid's last row: callers pass only typed rows
    /// (`TerminalRowSpace`), never an absolute row.
    private func readRows(tag: ghostty_point_tag_e, from first: Int, through last: Int) -> String? {
        guard let surface, first >= 0, last >= first else { return nil }
        let columns = max(1, grid.columns)
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(tag: tag, coord: GHOSTTY_POINT_COORD_EXACT, x: 0, y: UInt32(first)),
            bottom_right: ghostty_point_s(tag: tag, coord: GHOSTTY_POINT_COORD_EXACT, x: UInt32(columns - 1), y: UInt32(last)),
            rectangle: false
        )
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let pointer = text.text, text.text_len > 0 else { return "" }
        return String(decoding: UnsafeRawBufferPointer(start: pointer, count: Int(text.text_len)), as: UTF8.self)
    }

    /// Columns and rows of the local grid.
    var grid: (columns: Int, rows: Int) {
        guard let surface else { return (0, 0) }
        let size = ghostty_surface_size(surface)
        return (Int(size.columns), Int(size.rows))
    }

    /// The cursor's cell in this view's coordinates, when it is in the viewport.
    var visibleCursorCell: CGRect? {
        guard let surface else { return nil }
        var metrics = ghostty_surface_grid_metrics_s()
        guard ghostty_surface_grid_metrics(surface, &metrics), metrics.cursor_in_viewport, metrics.cell_height > 0 else { return nil }
        return CGRect(x: metrics.padding_left + Double(metrics.cursor_column) * metrics.cell_width,
                      y: metrics.padding_top + Double(metrics.cursor_row) * metrics.cell_height,
                      width: metrics.cell_width * Double(max(1, metrics.cursor_width_cells)),
                      height: metrics.cell_height)
    }

    /// The cursor row relative to the viewport top, when the cursor is in the viewport.
    var cursorViewportRow: Int? {
        guard let surface else { return nil }
        var metrics = ghostty_surface_grid_metrics_s()
        guard ghostty_surface_grid_metrics(surface, &metrics), metrics.cursor_in_viewport else { return nil }
        return Int(metrics.cursor_row)
    }

    /// Frames Ghostty's renderer drew for this surface (its render counters;
    /// zero before the surface exists). For tests and benchmarks.
    var renderedFrames: UInt64 {
        guard let surface else { return 0 }
        return ghostty_surface_render_counters(surface).frames
    }

    // MARK: Output and drawing

    /// Feeds one batch of session output on the output queue (never the
    /// main thread). `transform` (the row shift) runs there first, in feed
    /// order. `completion` runs on the main thread once Ghostty parsed the
    /// batch, after a draw was requested. The screen keeps one batch in
    /// flight (`TerminalViewController`'s output pump).
    func feed(_ data: Data, transform: (@Sendable (Data) -> Data)? = nil, completion: (@MainActor () -> Void)? = nil) {
        guard let surface else {
            pendingOutput.append(transform?(data) ?? data)
            completion?()
            return
        }
        let ref = SurfaceRef(surface)
        let done = completion.map(MainCallback.init)
        outputQueue.async {
            let bytes = transform?(data) ?? data
            bytes.withUnsafeBytes { raw in
                guard let base = raw.baseAddress?.assumingMemoryBound(to: CChar.self) else { return }
                ghostty_surface_process_output(ref.surface, base, UInt(raw.count))
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { [weak self] in
                // Ghostty also renders on its own after parsing, but later:
                // without this request a keystroke echo waited ~3x longer.
                self?.setNeedsTerminalDraw()
                done?.run()
            } }
        }
    }

    /// Asks Ghostty to move the viewport so `row` (0 = oldest scrollback row)
    /// is its top row. The frame for it is presented asynchronously (`onPresent`).
    func scroll(toRow row: Int) {
        guard let surface else { return }
        pinnedRow = row
        scrollViewport(row)
        ghostty_surface_refresh(surface)
    }

    /// Moves Ghostty's viewport to the active area; it re-renders and
    /// reports its scrollbar (used after leaving the alternate screen).
    func scrollToActiveArea() {
        guard let surface else { return }
        viewportEpoch += 1
        let action = "scroll_to_bottom"
        _ = action.withCString { ghostty_surface_binding_action(surface, $0, UInt(strlen($0))) }
        ghostty_surface_refresh(surface)
    }

    private func scrollViewport(_ row: Int) {
        guard let surface else { return }
        viewportEpoch += 1
        let action = "scroll_to_row:\(max(0, row))"
        _ = action.withCString { ghostty_surface_binding_action(surface, $0, UInt(strlen($0))) }
    }

    /// Asks the renderer for a frame.
    func setNeedsTerminalDraw() {
        guard let surface else { return }
        ghostty_surface_refresh(surface)
    }

    /// Draws now on the main thread from the current cells (resize, mode changes).
    func drawNow() {
        // A paused surface draws nothing (no GPU work in the background);
        // its reveal draws the current content.
        guard let surface, drawsFrames != false else { return }
        ghostty_surface_refresh(surface)
        ghostty_surface_draw(surface)
        draws += 1
    }

    /// Called on the main thread in the transaction that shows a new frame.
    var onPresent: (() -> Void)?

    /// The frame Ghostty presented last, as an image, and where its layer
    /// sits in this view. `drawHierarchy` leaves the Metal surface black in a
    /// snapshot taken while the page is live on screen (the active grid card,
    /// V5-6), so the snapshot draws this instead.
    func presentedImage(clip: CGRect? = nil) -> (image: CGImage, frame: CGRect)? {
        guard let sublayer = layer.sublayers?.first, let contents = sublayer.contents else { return nil }
        let ref = unsafeBitCast(contents as AnyObject, to: IOSurfaceRef.self)
        guard CFGetTypeID(ref) == IOSurfaceGetTypeID() else { return nil }
        let ioSurface = unsafeBitCast(ref, to: IOSurface.self)
        let image = CIImage(ioSurface: ioSurface)
        guard !image.extent.isEmpty, sublayer.frame.width > 0, sublayer.frame.height > 0 else { return nil }
        // Only the part `clip` (this view's points) shows: the whole 151-row
        // surface cost about 370 ms on the main thread (round 8).
        var frame = sublayer.frame
        var extent = image.extent
        if let clip {
            let visible = frame.intersection(clip)
            guard !visible.isNull, !visible.isEmpty else { return nil }
            let sx = image.extent.width / frame.width, sy = image.extent.height / frame.height
            let top = (visible.minY - frame.minY) * sy
            // Core Image's origin is at the bottom.
            extent = CGRect(x: (visible.minX - frame.minX) * sx, y: image.extent.height - top - visible.height * sy,
                            width: visible.width * sx, height: visible.height * sy).integral.intersection(image.extent)
            frame = visible
        }
        guard let cgImage = Self.snapshotContext.createCGImage(image, from: extent) else { return nil }
        return (cgImage, frame)
    }

    private static let snapshotContext = CIContext(options: [.cacheIntermediates: false])

    /// The rows of the presented frame that `clip` (this view's points)
    /// shows, copied out of Ghostty's IOSurface on the main thread (a memcpy
    /// of those rows), to be turned into an image on any thread
    /// (`PresentedCopy.makeImage`). The Core Image render of the frame took
    /// 150-214 ms of the main thread every 15 s while output streamed (V8
    /// claim 7); the copy is what the main thread still pays.
    func presentedCopy(clip: CGRect) -> TerminalPresentedCopy? {
        guard let sublayer = layer.sublayers?.first, let contents = sublayer.contents else { return nil }
        let source = unsafeBitCast(contents as AnyObject, to: IOSurfaceRef.self)
        guard CFGetTypeID(source) == IOSurfaceGetTypeID(), sublayer.frame.width > 0, sublayer.frame.height > 0 else { return nil }
        let visible = sublayer.frame.intersection(clip)
        guard !visible.isNull, !visible.isEmpty else { return nil }
        let width = IOSurfaceGetWidth(source), height = IOSurfaceGetHeight(source)
        let bytesPerElement = IOSurfaceGetBytesPerElement(source)
        guard width > 0, height > 0, bytesPerElement > 0 else { return nil }
        let sy = CGFloat(height) / sublayer.frame.height
        let firstRow = max(0, min(height, Int(floor((visible.minY - sublayer.frame.minY) * sy))))
        let lastRow = max(firstRow, min(height, Int(ceil((visible.maxY - sublayer.frame.minY) * sy))))
        guard lastRow > firstRow else { return nil }
        let properties: [String: Any] = [
            kIOSurfaceWidth as String: width,
            kIOSurfaceHeight as String: lastRow - firstRow,
            kIOSurfaceBytesPerElement as String: bytesPerElement,
            kIOSurfacePixelFormat as String: IOSurfaceGetPixelFormat(source),
        ]
        guard let copy = IOSurfaceCreate(properties as CFDictionary) else { return nil }
        IOSurfaceLock(source, .readOnly, nil)
        IOSurfaceLock(copy, [], nil)
        let sourceRow = IOSurfaceGetBytesPerRow(source), copyRow = IOSurfaceGetBytesPerRow(copy)
        let rowBytes = min(sourceRow, copyRow, width * bytesPerElement)
        let from = IOSurfaceGetBaseAddress(source), to = IOSurfaceGetBaseAddress(copy)
        for row in 0..<(lastRow - firstRow) {
            memcpy(to + row * copyRow, from + (firstRow + row) * sourceRow, rowBytes)
        }
        IOSurfaceUnlock(copy, [], nil)
        IOSurfaceUnlock(source, .readOnly, nil)
        // The colour space and other attachments, so the copy renders like the frame.
        if let values = IOSurfaceCopyAllValues(source) { IOSurfaceSetValues(copy, values) }
        let sx = CGFloat(width) / sublayer.frame.width
        let rowsFrame = CGRect(x: sublayer.frame.minX, y: sublayer.frame.minY + CGFloat(firstRow) / sy,
                               width: sublayer.frame.width, height: CGFloat(lastRow - firstRow) / sy)
        let columns = CGRect(x: (visible.minX - sublayer.frame.minX) * sx, y: 0, width: visible.width * sx,
                             height: CGFloat(lastRow - firstRow)).integral
        return TerminalPresentedCopy(surface: copy, columns: columns,
                             frame: CGRect(x: visible.minX, y: rowsFrame.minY, width: visible.width, height: rowsFrame.height))
    }


    /// One hash per cell row of the frame on screen (`rowHeight` px rows),
    /// sampled from the IOSurface Ghostty presented: two pixel lines through
    /// the glyphs, every third pixel. The screen matches consecutive frames'
    /// rows to learn which viewport a frame shows, whatever order Ghostty's
    /// frames and reports arrive in.
    /// `band`: only these rows are read; the others are
    /// `TerminalPresentMatch.unread` (following reads the rows on screen).
    func presentedRowSignatures(rowHeight: Int, band: Range<Int>? = nil) -> [UInt64]? {
        guard rowHeight > 2, let contents = layer.sublayers?.first?.contents else { return nil }
        let surface = unsafeBitCast(contents as AnyObject, to: IOSurfaceRef.self)
        guard CFGetTypeID(surface) == IOSurfaceGetTypeID() else { return nil }
        let bytesPerElement = IOSurfaceGetBytesPerElement(surface)
        guard bytesPerElement == 4 || bytesPerElement == 8 else { return nil }
        IOSurfaceLock(surface, .readOnly, nil)
        defer { IOSurfaceUnlock(surface, .readOnly, nil) }
        let base = IOSurfaceGetBaseAddress(surface).assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = IOSurfaceGetBytesPerRow(surface)
        let width = IOSurfaceGetWidth(surface)
        let height = IOSurfaceGetHeight(surface)
        let rows = height / rowHeight
        var result = [UInt64](repeating: TerminalPresentMatch.unread, count: rows)
        let read = band.map { $0.clamped(to: 0..<rows) } ?? 0..<rows
        // Pointer walk, no allocation per row: this runs for every presented
        // frame on the main thread. Same samples and hash as before: green
        // channel high nibble, every third pixel, two lines per row.
        let stride = 3 * bytesPerElement
        let lineBytes = width * bytesPerElement
        func sample(_ y: Int, into hash: inout UInt64) {
            guard y < height else { return }
            var pointer = base + y * bytesPerRow + 1
            let end = pointer + lineBytes
            while pointer < end {
                hash = (hash ^ UInt64(pointer.pointee >> 4)) &* 0x0000_0100_0000_01B3 // a high nibble survives blending noise
                pointer += stride
            }
        }
        result.withUnsafeMutableBufferPointer { out in
            for row in read {
                var hash: UInt64 = 0xcbf2_9ce4_8422_2325
                sample(row * rowHeight + rowHeight / 2, into: &hash)
                sample(row * rowHeight + rowHeight * 3 / 4, into: &hash)
                out[row] = hash == TerminalPresentMatch.unread ? 1 : hash
            }
        }
        return result
    }
    private(set) var presents = 0
    private var contentsObservation: NSKeyValueObservation?

    /// Ghostty's layer sets `contents` on the main thread for each presented
    /// frame (the probe in verify/terminal.md found no off-main sets).
    private weak var observedLayer: CALayer?

    private func observePresents() {
        guard let layer = layer.sublayers?.first, layer !== observedLayer else { return }
        observedLayer = layer
        contentsObservation = layer.observe(\.contents, options: []) { [weak self] _, _ in
            guard Thread.isMainThread else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                self.presents += 1
                self.presentPending = true
                self.observeCommits()
            }
        }
    }

    /// Ghostty can set `contents` more than once in one Core Animation
    /// transaction; only the last is ever displayed. The screen handles the
    /// present once, just before the transaction commits (a run loop
    /// observer ordered before Core Animation's commit), so the surface moves
    /// in the same transaction and the pixels it reads are the frame shown.
    /// (termqa D7: two presents 1 ms apart read a frame never displayed and
    /// then matched nothing; it also halves the reads in a busy stream.)
    private var presentPending = false
    private var commitObserver: CFRunLoopObserver?

    private func observeCommits() {
        guard commitObserver == nil else { return }
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.exit.rawValue,
                                                          true, 1_999_000) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self, self.presentPending else { return }
                self.presentPending = false
                self.onPresent?()
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        commitObserver = observer
    }

    func requestRedraw() { setNeedsTerminalDraw() }

    func receive(_ event: TerminalSurfaceEvent) {
        onEvent?(event)
    }

    // MARK: Input entry points for the key bar and the composer

    /// Sends the router's actions for a key bar key.
    func sendKey(usage: UInt16, mods: TerminalKeyMods = []) {
        perform(input.key(usage: usage, extra: mods))
    }

    func sendControl(_ letter: Character) {
        perform(input.control(letter))
    }

    func tapSticky(_ modifier: TerminalStickyModifiers.Modifier) {
        input.tapSticky(modifier, at: ProcessInfo.processInfo.systemUptime)
    }

    /// The composer's draft as one paste (bracketed when the program asked
    /// for it), then Return as its own keystroke a moment later
    /// (`ComposerSubmit`, Codex QA F1).
    func sendText(_ text: String, pressReturn: Bool, fullScreenApp: Bool = false) {
        perform(ComposerSubmit(text: text, pressReturn: pressReturn, fullScreenApp: fullScreenApp))
    }

    func perform(_ submit: ComposerSubmit) {
        for step in submit.steps {
            switch step {
            case .paste(let draft):
                perform([.paste(draft)])
            case .type(let draft):
                perform([.text(draft)])
            case .enter where submit.delaysEnter:
                let wait = submit.enterWait ?? ComposerSubmit.enterDelay
                Task { @MainActor [weak self] in
                    try? await ContinuousClock().sleep(for: wait)
                    guard let self else { return }
                    self.perform(self.input.plainKey(usage: TerminalHIDUsage.enter))
                }
            case .enter:
                perform(input.plainKey(usage: TerminalHIDUsage.enter))
            }
        }
    }

    // MARK: Responder

    override var canBecomeFirstResponder: Bool { true }

    @discardableResult
    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocusChange?(true) }
        return became
    }

    @discardableResult
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            if input.markedText != nil { perform(input.setMarkedText(nil)) }
            onFocusChange?(false)
        }
        return resigned
    }

    override var keyCommands: [UIKeyCommand]? { navigationKeyCommands() }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = beginPresses(presses)
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = endPresses(presses)
        if !unhandled.isEmpty { super.pressesEnded(unhandled, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = endPresses(presses)
        if !unhandled.isEmpty { super.pressesCancelled(unhandled, with: event) }
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)) { return UIPasteboard.general.hasStrings }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        guard let text = UIPasteboard.general.string, !text.isEmpty else { return }
        // A paste is not a key: an armed modifier would linger unseen (classic disarms).
        input.sticky.reset()
        perform([.paste(text)])
    }

    // MARK: Paste control (Codex QA F14)

    /// What the key bar's system paste control may hand this view: text.
    /// A tap on a `UIPasteControl` is the person's explicit paste, so iOS
    /// asks nothing ("Allow Paste" appeared for every new clipboard when the
    /// key read the pasteboard itself).
    func configurePasteControlTarget() {
        pasteConfiguration = UIPasteConfiguration(acceptableTypeIdentifiers: [UTType.plainText.identifier, UTType.utf8PlainText.identifier])
    }

    override func paste(itemProviders: [NSItemProvider]) {
        for provider in itemProviders where provider.canLoadObject(ofClass: NSString.self) {
            _ = provider.loadObject(ofClass: NSString.self) { [weak self] object, _ in
                guard let text = object as? String, !text.isEmpty else { return }
                DispatchQueue.main.async {
                    self?.input.sticky.reset()
                    self?.perform([.paste(text)])
                }
            }
            return
        }
    }

    override func canPaste(_ itemProviders: [NSItemProvider]) -> Bool {
        itemProviders.contains { $0.canLoadObject(ofClass: NSString.self) }
    }
}

/// A main-thread callback carried through the output queue.
private struct MainCallback: @unchecked Sendable {
    let body: @MainActor () -> Void
    init(_ body: @escaping @MainActor () -> Void) { self.body = body }
    @MainActor func run() { body() }
}

struct SurfaceRef: @unchecked Sendable {
    let surface: ghostty_surface_t
    init(_ surface: ghostty_surface_t) { self.surface = surface }
}

@MainActor
/// The surface's userdata for both callbacks. It outlives the view (it is
/// released only after `ghostty_surface_free`, which runs asynchronously
/// after the view's deinit), so actions Ghostty delivers in between find a
/// nil `view` instead of a dangling pointer.
final class InputBox {
    var deliver: ((Data) -> Void)?
    weak var view: TerminalSurfaceView?
}

private struct Retained: @unchecked Sendable {
    let object: AnyObject
    init(_ object: AnyObject) { self.object = object }
}

/// One row per read, in the numbering its type names (round 8: an absolute
/// row given as a screen y read a clamped, unrelated row).
extension TerminalSurfaceView: TerminalRowTextSource {
    func text(_ row: TerminalViewportRow) -> String? { readRows(tag: GHOSTTY_POINT_VIEWPORT, from: row.index, through: row.index) }
    func text(_ row: TerminalActiveRow) -> String? { readRows(tag: GHOSTTY_POINT_ACTIVE, from: row.index, through: row.index) }
    func text(_ row: TerminalScreenRow) -> String? { readRows(tag: GHOSTTY_POINT_SCREEN, from: row.index, through: row.index) }
    func text(screenRowsThrough last: TerminalScreenRow) -> String? { readRows(tag: GHOSTTY_POINT_SCREEN, from: 0, through: last.index) }
}
/// Rows of a presented frame, copied (`presentedCopy`).
struct TerminalPresentedCopy: @unchecked Sendable {
    let surface: IOSurfaceRef
    /// The copy's pixel columns that are shown (top-left origin).
    let columns: CGRect
    /// Where those pixels go, in the surface view's points.
    let frame: CGRect

    private nonisolated(unsafe) static let context = CIContext(options: [.cacheIntermediates: false])

    /// The image, on any thread (Core Image's context is thread safe).
    func makeImage() -> CGImage? {
        let image = CIImage(ioSurface: unsafeBitCast(surface, to: IOSurface.self))
        guard !image.extent.isEmpty else { return nil }
        // Core Image's origin is at the bottom; the columns span every row.
        let extent = CGRect(x: columns.minX, y: image.extent.height - columns.maxY, width: columns.width,
                            height: columns.height).intersection(image.extent)
        guard !extent.isEmpty else { return nil }
        return Self.context.createCGImage(image, from: extent)
    }
}

#endif
