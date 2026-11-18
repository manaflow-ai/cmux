#if DEBUG || CMUX_BENCH_HOOKS
public import AppKit
import CmuxNextCompat
import CmuxNextDesign
public import CmuxNextSettings
import CmuxNextWakeups
import ImageIO

/// Debug: Liquid Glass Parity (`debug.glass_parity`, DEV and NIGHTLY; Lawrence 2026-11-18: "make liquid
/// glass in web UI pixel perfect with macos liquid glass, it needs to handle like the transparent webview
/// bgs we have, make same thing in both swift and web and we need it to match perfectly").
///
/// One window, one backdrop under all of it, and every glass surface the web UI draws, three times side
/// by side over the same backdrop pixels: natively (the App's own surface of that role, as its native
/// menus, hover cards, tooltips and dialogs draw it), in a see-through WebKit page and in a see-through
/// Chromium page of the real web UI (webviews/src/pages/glass-parity: glass.css, popupSurface.css and
/// the tooltip surface, nothing of its own). The page draws in one of two modes:
///
/// - `host`: the App's own glass under the page at each surface's box (host glass, as the agent pane
///   draws its menus and popovers: ``Glass/hostGlassRole(_:)`` at ``Glass/hostTintLevel(_:)``), and the page lays only the veil and
///   the content on it. The material is then the native one, so this is the path that can match.
/// - `css`: the page's own glass alone, what a web surface shows without the App's glass under it.
///
/// Backdrops (``Backdrop``): the plain window color, a detailed wallpaper, an opaque terminal, a
/// terminal at 0.6 opacity over the wallpaper (cmux's terminal transparency over a custom background),
/// and a photo (the Mac's own desktop picture, else the wallpaper). Each column draws the backdrop in its
/// own coordinates, so the pixels under a surface are the same in every column and a pixel diff of one
/// cell against its native neighbor measures the glass and nothing else.
///
/// `measure` captures the window as the window server composites it (the App's `debug.window_snapshot`,
/// handed in as `capture`: the WebKit page in place, Chromium's own image of its page over the App's
/// glass) and answers each web surface's ``GlassParityDiff`` against the native one, with and without its
/// text. The capture's decoding, cropping, diffing and writing run off the main actor.
@MainActor
public final class GlassParityPlayground {
    nonisolated enum Kind: String, CaseIterable, Sendable {
        case menu, card, tooltip, dialog
    }

    nonisolated enum Backdrop: String, CaseIterable, Sendable {
        case plain, wallpaper, terminal
        case terminalTranslucent = "terminal-translucent"
        case image
    }

    nonisolated enum Mode: String, CaseIterable, Sendable {
        case host, css
    }

    nonisolated enum Column: String, CaseIterable, Sendable {
        case native, webkit, chromium
    }

    // MARK: Geometry (points; the pages run at zoom 1, so CSS px are points)

    static let columnWidth: CGFloat = 300
    static let rowHeight: CGFloat = 116
    static let surfaceOrigin = CGPoint(x: 30, y: 22)
    /// The content box inside a surface where its text draws (left out of the material diff).
    static let textInset = NSEdgeInsets(top: 8, left: 10, bottom: 0, right: 10)
    static let textHeight: CGFloat = 38

    static func surfaceSize(_ kind: Kind) -> CGSize {
        switch kind {
        case .tooltip: CGSize(width: 180, height: 56)
        default: CGSize(width: 240, height: 72)
        }
    }

    static func radius(_ kind: Kind) -> CGFloat {
        switch kind {
        case .menu: GlassMenuMaterial.cornerRadius
        case .card: Metrics.panelCornerRadius
        case .tooltip: 6
        case .dialog: 16
        }
    }

    /// A surface's box in its column (flipped, top-left origin).
    static func surfaceRect(_ kind: Kind) -> CGRect {
        let row = CGFloat(Kind.allCases.firstIndex(of: kind) ?? 0)
        return CGRect(origin: CGPoint(x: surfaceOrigin.x, y: surfaceOrigin.y + row * rowHeight), size: surfaceSize(kind))
    }

    static var contentSize: CGSize {
        CGSize(width: columnWidth * CGFloat(Column.allCases.count), height: rowHeight * CGFloat(Kind.allCases.count))
    }

    static func title(_ kind: Kind) -> String { "Liquid Glass" }
    static func detail(_ kind: Kind) -> String {
        switch kind {
        case .menu: "Menu"
        case .card: "Hover card"
        case .tooltip: "Tooltip"
        case .dialog: "Dialog"
        }
    }

    // MARK: State

    private(set) var window: NSWindow?
    private(set) var backdrop: Backdrop = .wallpaper
    private(set) var mode: Mode = .host
    private var pages: [Column: PageWebView] = [:]
    private var hosts: [Column: GlassParityHostLayer] = [:]
    private var backdrops: [GlassParityBackdropView] = []
    private var ready: Set<Column> = []
    /// The Mac's desktop picture for the `image` backdrop, read off the main actor once.
    private var picture: NSImage?
    private var pictureRead = false
    /// The waits below: woken by the pages' reports and by one deadline, never by polling.
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let deadline = DemandTimer(owner: "glass-parity")
    private var deadlinePassed = false

    public init() {}

    /// The layout the page in `column` shows (`cmux.glass_parity.layout`).
    func layout(for column: Column) -> JSONValue {
        let cells: [JSONValue] = Kind.allCases.map { kind in
            let rect = Self.surfaceRect(kind)
            return [
                "id": .string(kind.rawValue), "kind": .string(kind.rawValue),
                "left": .number(rect.minX), "top": .number(rect.minY),
                "width": .number(rect.width), "height": .number(rect.height),
                "radius": .number(Self.radius(kind)),
                "title": .string(Self.title(kind)), "detail": .string(Self.detail(kind)),
            ]
        }
        return ["mode": .string(mode.rawValue), "cells": .array(cells)]
    }

    /// A page's report of its surfaces' boxes (host mode): the App's glass goes there.
    func surfaces(_ params: JSONValue, from column: Column) throws -> JSONValue {
        guard case .array(let list)? = params["surfaces"], list.count <= 16 else {
            throw PageError(code: "cmux.glass_parity.bad_surfaces", message: "surfaces must be a list of at most 16")
        }
        var surfaces: [GlassParityHostLayer.Surface] = []
        for item in list {
            guard let id = item["id"]?.stringValue, let name = item["level"]?.stringValue,
                  let level = GlassLevel(rawValue: name), level != .chrome,
                  let left = item["left"]?.doubleValue, let top = item["top"]?.doubleValue,
                  let right = item["right"]?.doubleValue, let bottom = item["bottom"]?.doubleValue,
                  right >= left, bottom >= top else {
                throw PageError(code: "cmux.glass_parity.bad_surfaces", message: "a surface is malformed")
            }
            surfaces.append(.init(id: id, level: level, rect: CGRect(x: left, y: top, width: right - left, height: bottom - top),
                                  radius: item["radius"]?.doubleValue ?? 0, opacity: item["opacity"]?.doubleValue ?? 1))
        }
        hosts[column]?.apply(surfaces)
        wake()
        return ["drawn": .number(Double(surfaces.count))]
    }

    /// A page painted its layout (`cmux.glass_parity.ready`).
    func pageReady(_ column: Column) {
        ready.insert(column)
        wake()
    }

    // MARK: Open and configure

    /// Opens the playground (or reconfigures it) on `backdrop` in `mode`, on a screen of backing `scale`
    /// when one is attached, and waits until both pages painted (and, in host mode, the App drew their
    /// glass). Answers what it shows.
    func show(backdrop: Backdrop, mode: Mode, scale: CGFloat?) async -> JSONValue {
        let reload = window == nil || mode != self.mode
        self.backdrop = backdrop
        self.mode = mode
        let window = window ?? makeWindow()
        self.window = window
        if let scale { place(window, scale: scale) }
        if backdrop == .image, !pictureRead {
            pictureRead = true
            picture = await Self.readDesktopPicture().flatMap(NSImage.init(data:))
        }
        for view in backdrops {
            view.backdrop = backdrop
            view.picture = picture
            view.needsDisplay = true
        }
        if reload {
            ready = []
            for host in hosts.values { host.apply([]) }
            for page in pages.values { page.reload() }
        }
        window.orderFrontRegardless()
        await wait(until: { self.ready.count >= self.pages.count }, limit: .seconds(15))
        if mode == .host {
            await wait(until: { !self.hosts.values.contains { $0.count < Kind.allCases.count } }, limit: .seconds(4))
        }
        // Liquid Glass settles its adaptive look over a new backdrop over a few frames.
        await wait(until: { false }, limit: .milliseconds(700))
        return status()
    }

    func status() -> JSONValue {
        guard let window else { return ["open": false] }
        var engines: [String: JSONValue] = [:]
        for (column, page) in pages { engines[column.rawValue] = .string(page.chromiumPage == nil ? "webkit" : "chromium") }
        var drawn: [String: JSONValue] = [:]
        for (column, host) in hosts { drawn[column.rawValue] = .number(Double(host.count)) }
        return [
            "open": true, "window": .number(Double(window.windowNumber)),
            "scale": .number(window.backingScaleFactor), "backdrop": .string(backdrop.rawValue), "mode": .string(mode.rawValue),
            "appearance": .string(window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? "dark" : "light"),
            "engines": .object(engines), "host_glass": .object(drawn),
            "ready": .array(ready.map { .string($0.rawValue) }.sorted { ($0.stringValue ?? "") < ($1.stringValue ?? "") }),
            "liquid_glass": .bool(Glass.isLiquidGlassAvailable),
            "desktop_picture": .bool(picture != nil),
        ]
    }

    func close() {
        window?.orderOut(nil)
        window?.close()
        window = nil
        pages = [:]
        hosts = [:]
        backdrops = []
        ready = []
    }

    /// Waits until `done` holds or `limit` passes, woken by the pages' reports and one deadline.
    private func wait(until done: () -> Bool, limit: Duration) async {
        deadlinePassed = false
        deadline.schedule(after: limit) { @MainActor [weak self] in
            self?.deadlinePassed = true
            self?.wake()
        }
        while !done(), !deadlinePassed {
            await withCheckedContinuation { waiters.append($0) }
        }
        deadline.cancel()
    }

    private func wake() {
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
    }

    private func place(_ window: NSWindow, scale: CGFloat) {
        guard let screen = NSScreen.screens.first(where: { $0.backingScaleFactor == scale }) else { return }
        let frame = window.frameRect(forContentRect: CGRect(origin: .zero, size: Self.contentSize))
        let origin = CGPoint(x: screen.visibleFrame.minX + 40, y: screen.visibleFrame.maxY - 40 - frame.height)
        window.setFrame(CGRect(origin: origin, size: frame.size), display: true)
    }

    private func makeWindow() -> NSWindow {
        let size = Self.contentSize
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "Liquid Glass Parity"
        window.isReleasedWhenClosed = false
        window.setAccessibilityIdentifier("cmux.glassParity")
        let root = GlassParityFlippedView(frame: CGRect(origin: .zero, size: size))
        window.contentView = root
        for (index, column) in Column.allCases.enumerated() {
            let frame = CGRect(x: CGFloat(index) * Self.columnWidth, y: 0, width: Self.columnWidth, height: size.height)
            let backdrop = GlassParityBackdropView(frame: frame)
            backdrop.backdrop = self.backdrop
            root.addSubview(backdrop)
            backdrops.append(backdrop)
            switch column {
            case .native:
                for kind in Kind.allCases { root.addSubview(nativeSurface(kind, in: frame)) }
            case .webkit, .chromium:
                let host = GlassParityHostLayer(frame: frame)
                root.addSubview(host)
                hosts[column] = host
                let provider = GlassParityProvider(playground: self, column: column)
                let options = column == .webkit ? PageEngineOptions(requiresWebKit: .transparentOverlay) : .standard
                guard let page = PageWebView(descriptor: .glassParity,
                                             routes: [PageRoute(prefix: "cmux.glass_parity.", provider: provider)],
                                             options: options) else { continue }
                page.followsUIScale = false
                page.frame = frame
                root.addSubview(page)
                pages[column] = page
            }
        }
        window.center()
        return window
    }

    /// The App's own surface for `kind`, as its native UI draws that role, with the same text.
    private func nativeSurface(_ kind: Kind, in column: CGRect) -> NSView {
        let radius = Self.radius(kind)
        let surface: OverlaySurfaceView = switch kind {
        case .menu: Glass.makeMenuPanel(cornerRadius: radius, interactive: false)
        case .card: Glass.makeSurface(.popover, cornerRadius: radius, interactive: false)
        case .tooltip: Glass.makeSurface(.tooltip, cornerRadius: radius, interactive: false)
        case .dialog: Glass.makeSurface(.sheet, cornerRadius: radius, interactive: false)
        }
        surface.translatesAutoresizingMaskIntoConstraints = true
        surface.frame = Self.surfaceRect(kind).offsetBy(dx: column.minX, dy: column.minY)
        let text = GlassParityTextView(frame: surface.contentView.bounds, title: Self.title(kind), detail: Self.detail(kind))
        text.autoresizingMask = [.width, .height]
        surface.contentView.addSubview(text)
        return surface
    }

    // MARK: Measure

    /// One surface's boxes in the capture's pixels: the cell (the surface and a margin, so its shadow and
    /// rim are in the diff) in each column, and its text inside the cell.
    nonisolated struct CellBoxes: Sendable {
        var kind: String
        var columns: [(column: String, box: CGRect)]
        var text: CGRect
    }

    /// Captures the window into `directory` through `capture` (the window and a PNG path; true once the
    /// PNG is written) and answers each web surface's diff against its native neighbor, with its text
    /// (`full`) and without (`material`), and writes every cell and its heat map beside the capture.
    public func measure(into directory: URL, capture: (NSWindow, URL) async -> JSONValue) async -> JSONValue {
        guard let window, let content = window.contentView else { return ["error": "the playground is not open"] }
        let appearance = window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? "dark" : "light"
        let scale = window.backingScaleFactor
        let stem = "\(backdrop.rawValue)-\(mode.rawValue)-\(appearance)-\(Int(scale))x"
        let png = directory.appending(path: "window-\(stem).png", directoryHint: .notDirectory)
        await Task.detached(priority: .utility) { try? FileManager.checked.createDirectory(at: directory, withIntermediateDirectories: true) }.value
        let snapshot = await capture(window, png)
        // The capture is the window's frame at its backing scale, title bar on top, no shadow.
        let contentInWindow = content.convert(content.bounds, to: nil)
        let contentTop = (window.frame.height - contentInWindow.maxY) * scale
        func pixelBox(_ rect: CGRect) -> CGRect {
            CGRect(x: rect.minX * scale, y: contentTop + rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
        }
        let cells = Kind.allCases.map { kind -> CellBoxes in
            let surface = Self.surfaceRect(kind)
            let box = surface.insetBy(dx: -8, dy: -8)
            let text = CGRect(x: (surface.minX - box.minX + Self.textInset.left) * scale,
                              y: (surface.minY - box.minY + Self.textInset.top) * scale,
                              width: (surface.width - Self.textInset.left - Self.textInset.right) * scale,
                              height: Self.textHeight * scale)
            let columns = Column.allCases.enumerated().map { index, column in
                (column.rawValue, pixelBox(box.offsetBy(dx: CGFloat(index) * Self.columnWidth, dy: 0)))
            }
            return CellBoxes(kind: kind.rawValue, columns: columns, text: text)
        }
        let expectedWidth = Int((window.frame.width * scale).rounded())
        let report = await Task.detached(priority: .utility) { Self.diffCells(png: png, directory: directory, stem: stem, cells: cells,
                                                          expectedWidth: expectedWidth) }.value
        var reply = report
        if case .object(var members) = reply {
            members["status"] = status()
            members["snapshot"] = snapshot
            reply = .object(members)
        }
        return reply
    }

    /// Reads the capture at `png`, crops every cell, writes the crops and heat maps, and diffs each web
    /// column against the native one (off the main actor).
    nonisolated static func diffCells(png: URL, directory: URL, stem: String, cells: [CellBoxes], expectedWidth: Int) -> JSONValue {
        guard let source = CGImageSourceCreateWithURL(png as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return ["error": "no capture"] }
        var out: [String: JSONValue] = [:]
        var worst: Double = 0
        var passes = true
        for cell in cells {
            var crops: [String: (bytes: [UInt8], width: Int, height: Int)] = [:]
            for (column, box) in cell.columns {
                guard let crop = GlassParityDiff.pixels(of: image, in: box) else { continue }
                crops[column] = crop
                writePNG(crop, to: directory.appending(path: "\(cell.kind)-\(column)-\(stem).png", directoryHint: .notDirectory))
            }
            guard let native = crops[Column.native.rawValue] else { continue }
            var row: [String: JSONValue] = [:]
            for column in [Column.webkit.rawValue, Column.chromium.rawValue] {
                guard let web = crops[column], web.width == native.width, web.height == native.height else { continue }
                let full = GlassParityDiff.compare(native.bytes, web.bytes, width: web.width, height: web.height,
                                                   bytesPerRow: web.width * 4)
                let material = GlassParityDiff.compare(native.bytes, web.bytes, width: web.width, height: web.height,
                                                       bytesPerRow: web.width * 4, excluded: [cell.text])
                if let material {
                    worst = Swift.max(worst, material.mean)
                    if !material.within(GlassParityDiff.hostTolerance) { passes = false }
                }
                row[column] = [
                    "full": full.map { JSONValue.object($0.json.mapValues(JSONValue.number)) } ?? .null,
                    "material": material.map { JSONValue.object($0.json.mapValues(JSONValue.number)) } ?? .null,
                ]
                writeDiffPNG(native, web, to: directory.appending(path: "\(cell.kind)-\(column)-diff-\(stem).png",
                                                                  directoryHint: .notDirectory))
            }
            out[cell.kind] = .object(row)
        }
        return [
            "window_png": .string(png.path), "stem": .string(stem), "cells": .object(out),
            "image_width": .number(Double(image.width)), "expected_width": .number(Double(expectedWidth)),
            "tolerance": ["mean": .number(GlassParityDiff.hostTolerance.mean), "p99": .number(Double(GlassParityDiff.hostTolerance.p99))],
            "within_tolerance": .bool(passes), "worst_material_mean": .number((worst * 1000).rounded() / 1000),
        ]
    }

    private nonisolated static func image(_ crop: (bytes: [UInt8], width: Int, height: Int)) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(crop.bytes) as CFData) else { return nil }
        return CGImage(width: crop.width, height: crop.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: crop.width * 4,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    private nonisolated static func writePNG(_ crop: (bytes: [UInt8], width: Int, height: Int), to url: URL) {
        guard let image = image(crop),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }

    /// The per-pixel error as a heat image: black where equal, brighter with the error (x8, so a step of
    /// 32 is white).
    private nonisolated static func writeDiffPNG(_ a: (bytes: [UInt8], width: Int, height: Int),
                                                 _ b: (bytes: [UInt8], width: Int, height: Int), to url: URL) {
        var bytes = [UInt8](repeating: 255, count: a.bytes.count)
        for i in stride(from: 0, to: a.bytes.count, by: 4) {
            let error = Swift.max(abs(Int(a.bytes[i]) - Int(b.bytes[i])), abs(Int(a.bytes[i + 1]) - Int(b.bytes[i + 1])),
                                  abs(Int(a.bytes[i + 2]) - Int(b.bytes[i + 2])))
            let value = UInt8(Swift.min(255, error * 8))
            bytes[i] = value
            bytes[i + 1] = value
            bytes[i + 2] = value
        }
        writePNG((bytes, a.width, a.height), to: url)
    }

    /// The first desktop picture the Mac ships (sorted by path), as its file's bytes, read off the main actor.
    static func readDesktopPicture() async -> Data? {
        await Task.detached(priority: .utility) {
            for root in ["/System/Library/Desktop Pictures", "/Library/Desktop Pictures"] {
                let base = URL(fileURLWithPath: root, isDirectory: true)
                guard let walker = FileManager.checked.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
                let pictures = walker.compactMap { $0 as? URL }
                    .filter { ["heic", "jpg", "jpeg", "png"].contains($0.pathExtension.lowercased()) }
                    .filter { !$0.path.lowercased().contains("thumbnail") }
                    .sorted { $0.path < $1.path }
                for picture in pictures {
                    if let data = try? Data(blockingContentsOf: picture), !data.isEmpty { return data }
                }
            }
            return nil
        }.value
    }

    // MARK: Control

    /// `debug.glass_parity {backdrop?, mode?, scale?, measure?, dir?, close?}` (the App routes it here):
    /// opens or reconfigures the playground (``show(backdrop:mode:scale:)``) and, with `measure`, captures
    /// and diffs it into `dir` (default a folder in the temporary directory). `close` closes it.
    public func handle(_ params: [String: JSONValue], capture: (NSWindow, URL) async -> JSONValue) async -> JSONValue {
        if params["close"]?.boolValue == true {
            close()
            return ["open": false]
        }
        let backdrop = params["backdrop"]?.stringValue.flatMap(Backdrop.init(rawValue:)) ?? backdrop
        let mode = params["mode"]?.stringValue.flatMap(Mode.init(rawValue:)) ?? mode
        let scale = params["scale"]?.doubleValue.map { CGFloat($0) }
        let shown = await show(backdrop: backdrop, mode: mode, scale: scale)
        guard params["measure"]?.boolValue == true else { return shown }
        let directory = params["dir"]?.stringValue.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appending(path: "glass-parity", directoryHint: .isDirectory)
        return await measure(into: directory, capture: capture)
    }
}

/// The page provider of one web column: its layout, its surfaces' boxes, its first paint.
@MainActor
final class GlassParityProvider: PageProvider {
    private weak var playground: GlassParityPlayground?
    private let column: GlassParityPlayground.Column

    init(playground: GlassParityPlayground, column: GlassParityPlayground.Column) {
        self.playground = playground
        self.column = column
    }

    func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        guard let playground else { throw PageError.unknownOp(op) }
        switch op {
        case "cmux.glass_parity.layout": return playground.layout(for: column)
        case "cmux.glass_parity.surfaces": return try playground.surfaces(params, from: column)
        case "cmux.glass_parity.ready":
            playground.pageReady(column)
            return .null
        default: throw PageError.unknownOp(op)
        }
    }
}

/// The App's glass under one web column (host glass): a surface per reported box, under the page.
@MainActor
final class GlassParityHostLayer: NSView {
    struct Surface: Equatable {
        var id: String
        var level: GlassLevel
        var rect: CGRect
        var radius: CGFloat
        var opacity: CGFloat
    }

    private var views: [String: (level: GlassLevel, view: OverlaySurfaceView)] = [:]
    var count: Int { views.count }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func apply(_ surfaces: [Surface]) {
        var kept = Set<String>()
        for surface in surfaces {
            kept.insert(surface.id)
            if views[surface.id]?.level != surface.level {
                views[surface.id]?.view.removeFromSuperview()
                // As the agent pane draws its host glass (AgentPaneView+HostGlass.swift).
                let view = Glass.makeSurface(Glass.hostGlassRole(surface.level), interactive: false)
                view.tintLevel = Glass.hostTintLevel(surface.level)
                view.translatesAutoresizingMaskIntoConstraints = true
                addSubview(view)
                views[surface.id] = (surface.level, view)
            }
            guard let view = views[surface.id]?.view else { continue }
            if view.frame != surface.rect { view.frame = surface.rect }
            if view.cornerRadius != surface.radius { view.cornerRadius = surface.radius }
            if view.alphaValue != surface.opacity { view.alphaValue = surface.opacity }
        }
        for (id, entry) in views where !kept.contains(id) {
            entry.view.removeFromSuperview()
            views[id] = nil
        }
    }
}

final class GlassParityFlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// A surface's two lines, in the type the web cells draw (the body size, 13 pt on 18 pt lines, 8 pt from
/// the top and 12 pt from the left: `--ds-space-2` and `--ds-space-3`), primary then secondary ink.
final class GlassParityTextView: NSView {
    init(frame: NSRect, title: String, detail: String) {
        super.init(frame: frame)
        for (index, (text, color)) in [(title, Palette.textPrimary), (detail, Palette.textSecondary)].enumerated() {
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: TypeScale.body)
            label.textColor = color
            label.frame = CGRect(x: 12, y: 8 + CGFloat(index) * 18, width: frame.width - 24, height: 18)
            label.autoresizingMask = [.width]
            addSubview(label)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
#endif
