#if DEBUG || CMUX_BENCH_HOOKS
public import AppKit
import CmuxNextCompat
import CmuxNextDesign
public import CmuxNextSettings
import CmuxNextWakeups

/// Debug: Liquid Glass Parity (`debug.glass_parity`, DEV and NIGHTLY; Lawrence 2026-11-18: "make liquid
/// glass in web UI pixel perfect with macos liquid glass, it needs to handle like the transparent webview
/// bgs we have, make same thing in both swift and web and we need it to match perfectly", then "make sure
/// we overlay on top of each other and do pixel matching stuff so we are 100% matching liquid glass in
/// every single scenario").
///
/// One window, one backdrop, and every glass surface the web UI draws, rendered three times **on top of
/// each other at the same boxes**: natively (the App's own surface of that role, as its native menus,
/// popovers, hover cards, tooltips, dialog cards and toasts draw it), in a see-through WebKit page and in a
/// see-through Chromium page of the real web UI (webviews/src/pages/glass-parity: glass.css,
/// popupSurface.css, notice.css and the tooltip surface, nothing of its own). One renderer shows at a time
/// (``solo(_:)``), so each capture has the same window, frame, screen position and backdrop pixels, and
/// only the glass differs. The page draws in one of two modes:
///
/// - `host`: the App's own glass under the page at each surface's box (host glass, as the agent pane
///   draws its menus and popovers: ``Glass/hostGlassRole(_:)`` or the role the surface names, at
///   ``Glass/hostTintLevel(_:)``), and the page lays only the veil and the content on it.
/// - `css`: the page's own glass alone, what a web surface shows without the App's glass under it.
///
/// A scenario (``Scenario``) is the backdrop (the plain window color, a custom color, a detailed
/// wallpaper, a terminal at any background opacity over the wallpaper, the Mac's desktop picture), its
/// offset (the backdrop moved under the glass), the window active or not, and the mode; appearance,
/// backing scale and Reduce Transparency come from the App (`debug.appearance`, the screen, and
/// `debug.reduce_transparency`). `measure` captures each renderer through `capture` (the App's
/// `debug.window_snapshot`) and writes, per surface, each renderer's crop, the onion skin (web over
/// native at half opacity) and the difference, with ``GlassParityDiff`` numbers (+Measure.swift).
@MainActor
public final class GlassParityPlayground {
    nonisolated enum Kind: String, CaseIterable, Sendable {
        case menu, popover, card, tooltip, dialog, toast, chrome
    }

    /// The menu's row under the pointer: none, hovered (the highlight), or pressed (the press fill).
    nonisolated enum RowState: String, CaseIterable, Sendable {
        case rest, hover, pressed
    }

    nonisolated enum Backdrop: String, CaseIterable, Sendable {
        case plain, color, wallpaper, terminal, image
    }

    nonisolated enum Mode: String, CaseIterable, Sendable {
        case host, css
    }

    /// The renderers stacked on the stage.
    nonisolated enum Column: String, CaseIterable, Sendable {
        case native, webkit, chromium
    }

    /// Everything a capture depends on that the playground sets itself.
    /// How the text on the glass is rasterized: `standard` is what the app ships (AppKit's own text beside
    /// the pages', which follow it under `appearance.fontSmoothing` `auto`); `flat` draws both with font
    /// smoothing off; `smooth` both with it on.
    nonisolated enum TextRendering: String, Sendable { case standard, flat, smooth }

    nonisolated struct Scenario: Equatable, Sendable {
        var backdrop: Backdrop = .wallpaper
        var mode: Mode = .host
        /// The custom background color of `color` (0xRRGGBB).
        var color: UInt32 = 0x2D6CDF
        /// The terminal's background opacity (`terminal`: below 1 the wallpaper shows through it).
        var opacity: CGFloat = 1
        /// How far the backdrop moved under the glass (points, down and right).
        var offset: CGFloat = 0
        /// The window key and its app active, else inactive.
        var active = true
        /// The menu's highlighted row (``menuRow``): none, hovered or pressed.
        var row: RowState = .rest
        /// How the text is rasterized on each side (``TextRendering``).
        var text: TextRendering = .standard

        var stem: String {
            var parts = [backdrop.rawValue]
            if backdrop == .color { parts.append(String(format: "%06x", color)) }
            if backdrop == .terminal { parts.append("o\(Int((opacity * 100).rounded()))") }
            if offset != 0 { parts.append("s\(Int(offset.rounded()))") }
            parts.append(mode.rawValue)
            parts.append(active ? "active" : "inactive")
            if row != .rest { parts.append(row.rawValue) }
            if text != .standard { parts.append("text-\(text.rawValue)") }
            return parts.joined(separator: "-")
        }
    }

    // MARK: Geometry (points; the pages run at zoom 1, so CSS px are points)

    static let cellWidth: CGFloat = 300
    static let rowHeight: CGFloat = 116
    static let gridColumns = 2
    static let surfaceOrigin = CGPoint(x: 30, y: 22)
    /// The content box inside a surface where its text draws (left out of the material diff).
    static let textInset = NSEdgeInsets(top: 8, left: 10, bottom: 0, right: 10)
    static let textHeight: CGFloat = 38
    /// The menu's one row (in the menu, below its text): a native menu row's box at the menu's highlight
    /// inset, where the hover and pressed cells draw its highlight.
    static var menuRow: CGRect {
        let inset = MenuMetrics.highlightInset
        return CGRect(x: inset, y: 47, width: surfaceSize(.menu).width - inset * 2, height: 20)
    }
    /// The native row highlight's corner (``PopupRowView``'s, `PopupStyle.standard.rowCornerRadius`).
    static var menuRowRadius: CGFloat { PopupStyle.standard.rowCornerRadius }

    static func surfaceSize(_ kind: Kind) -> CGSize {
        switch kind {
        case .tooltip: CGSize(width: 180, height: 56)
        default: CGSize(width: 240, height: 72)
        }
    }

    static func radius(_ kind: Kind) -> CGFloat {
        switch kind {
        case .menu: GlassMenuMaterial.cornerRadius
        case .popover, .card: Metrics.panelCornerRadius
        case .tooltip: 6
        case .dialog: 16
        case .toast, .chrome: Metrics.surfaceCornerRadius
        }
    }

    /// A surface's box on the stage (flipped, top-left origin): the surfaces in a grid of
    /// ``gridColumns``, every renderer's at the same box.
    static func surfaceRect(_ kind: Kind) -> CGRect {
        let index = Kind.allCases.firstIndex(of: kind) ?? 0
        let column = CGFloat(index % gridColumns), row = CGFloat(index / gridColumns)
        return CGRect(origin: CGPoint(x: column * cellWidth + surfaceOrigin.x, y: row * rowHeight + surfaceOrigin.y),
                      size: surfaceSize(kind))
    }

    static var contentSize: CGSize {
        let rows = (Kind.allCases.count + gridColumns - 1) / gridColumns
        return CGSize(width: cellWidth * CGFloat(gridColumns), height: rowHeight * CGFloat(rows))
    }

    static func title(_ kind: Kind) -> String { "Liquid Glass" }
    static func detail(_ kind: Kind) -> String {
        switch kind {
        case .menu: "Menu"
        case .popover: "Popover"
        case .card: "Hover card"
        case .tooltip: "Tooltip"
        case .dialog: "Dialog"
        case .toast: "Toast"
        case .chrome: "Chrome"
        }
    }

    // MARK: State

    private(set) var window: NSWindow?
    private(set) var scenario = Scenario()
    var pages: [Column: PageWebView] = [:]
    var hosts: [Column: GlassParityHostLayer] = [:]
    private var backdropView: GlassParityBackdropView?
    private(set) var nativeLayer: NSView?
    /// The native menu's row highlight (``Scenario/row``).
    private var menuRowView: GlassParityRowFill?
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
                "row": .string(kind == .menu ? scenario.row.rawValue : RowState.rest.rawValue),
                "title": .string(Self.title(kind)), "detail": .string(Self.detail(kind)),
            ]
        }
        let row = Self.menuRow
        return ["mode": .string(scenario.mode.rawValue), "text": .string(scenario.text.rawValue), "cells": .array(cells),
                "menu_row": ["left": .number(row.minX), "top": .number(row.minY), "width": .number(row.width),
                             "height": .number(row.height), "radius": .number(Self.menuRowRadius)]]
    }

    /// A page's report of its surfaces' boxes (host mode): the App's glass goes there.
    func surfaces(_ params: JSONValue, from column: Column) throws -> JSONValue {
        guard case .array(let list)? = params["surfaces"], list.count <= 16 else {
            throw PageError(code: "cmux.glass_parity.bad_surfaces", message: "surfaces must be a list of at most 16")
        }
        var surfaces: [GlassParityHostLayer.Surface] = []
        for item in list {
            guard let id = item["id"]?.stringValue, let name = item["level"]?.stringValue,
                  let level = GlassLevel(rawValue: name),
                  let left = item["left"]?.doubleValue, let top = item["top"]?.doubleValue,
                  let right = item["right"]?.doubleValue, let bottom = item["bottom"]?.doubleValue,
                  right >= left, bottom >= top else {
                throw PageError(code: "cmux.glass_parity.bad_surfaces", message: "a surface is malformed")
            }
            var role: SurfaceRole?
            if let named = item["role"]?.stringValue {
                guard let known = Glass.hostGlassRoles[named] else {
                    throw PageError(code: "cmux.glass_parity.bad_surfaces", message: "a surface's role is unknown")
                }
                role = known
            }
            surfaces.append(.init(id: id, level: level, role: role, rect: CGRect(x: left, y: top, width: right - left, height: bottom - top),
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

    /// Opens the playground (or reconfigures it) for `scenario`, on a screen of backing `scale` when one
    /// is attached, and waits until both pages painted (and, in host mode, the App drew their glass).
    /// Answers what it shows.
    func show(_ scenario: Scenario, scale: CGFloat?) async -> JSONValue {
        // Every scenario starts from new glass, native and host alike: Liquid Glass keeps an adaptive look with
        // memory (over the same backdrop the tooltip's glass settled on two or three looks, by the backdrops it
        // saw before: fleet step 368e35ec), so glass views with different pasts drifted apart by up to 12 levels.
        // New views have the same (no) past. The pages reload so each reports its surfaces to new host glass.
        self.scenario = scenario
        let window = window ?? makeWindow()
        self.window = window
        if let scale { place(window, scale: scale) }
        if scenario.backdrop == .image, !pictureRead {
            pictureRead = true
            picture = await Self.readDesktopPicture().flatMap(NSImage.init(data:))
        }
        if let view = backdropView {
            view.backdrop = scenario.backdrop
            view.picture = picture
            view.color = scenario.color
            view.terminalOpacity = scenario.opacity
            view.offset = scenario.offset
            view.needsDisplay = true
        }
        if let native = nativeLayer {
            for view in native.subviews { view.removeFromSuperview() } // visible-only: the seven fixed test surfaces, all on screen
            for kind in Kind.allCases { native.addSubview(nativeSurface(kind)) }
        }
        ready = []
        for host in hosts.values { host.apply([]) }
        for page in pages.values { page.reload() }
        // Every page loads and reports while shown; the capture solos one renderer at a time after.
        solo(nil)
        // Active: the app active and the playground key (the harness launches the app without the no-activate switch
        // for these cells; under it macOS may refuse, and `status().key` says so). Activation lands a few frames
        // later and the app's own main window takes key as it does, so the playground asks for key again once the
        // app is active. Inactive: the harness hands activation to another app (`open -a Finder`, before this
        // call); here the playground only comes to the front without asking for it.
        if scenario.active {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            await poll(until: { NSApp.isActive }, limit: .seconds(3))
            // The app's own main window may take key as activation lands, after this asked: ask again until key.
            await poll(until: {
                if !window.isKeyWindow { window.makeKeyAndOrderFront(nil) }
                return window.isKeyWindow
            }, limit: .seconds(4))
        } else {
            window.orderFrontRegardless()
            await poll(until: { !NSApp.isActive }, limit: .seconds(3))
        }
        await wait(until: { self.ready.count >= self.pages.count }, limit: .seconds(15))
        if scenario.mode == .host {
            await wait(until: { !self.hosts.values.contains { $0.count < Kind.allCases.count } }, limit: .seconds(4))
        }
        await settle()
        return status()
    }

    /// Moves the backdrop under the glass every frame for `seconds` with only `column`'s renderer shown (nil:
    /// all), so `debug.frames` around it measures the frame time of that glass over a moving backdrop.
    func animate(seconds: Double, only column: Column?) async -> JSONValue {
        guard let backdropView else { return ["error": "the playground is not open"] }
        solo(column)
        await settle()
        let start = ContinuousClock.now
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            backdropView.animate(for: seconds) { done.resume() }
        }
        let elapsed = ContinuousClock.now - start
        solo(nil)
        var answer = status()
        if case .object(var members) = answer {
            members["animated_ms"] = .number(Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)
            members["column"] = column.map { .string($0.rawValue) } ?? .null
            answer = .object(members)
        }
        return answer
    }

    /// Shows only `column`'s renderer (nil: all of them), so a capture holds one renderer over the backdrop.
    func solo(_ column: Column?) {
        nativeLayer?.isHidden = column != nil && column != .native
        for (renderer, page) in pages {
            let hidden = column != nil && column != renderer
            page.isHidden = hidden
            hosts[renderer]?.isHidden = hidden
        }
    }

    /// Liquid Glass settles its adaptive look over a new backdrop, and a page shown again paints, over a
    /// few frames.
    func settle() async {
        await wait(until: { false }, limit: .milliseconds(700))
    }

    func status() -> JSONValue {
        guard let window else { return ["open": false] }
        var engines: [String: JSONValue] = [:]
        for (column, page) in pages { engines[column.rawValue] = .string(page.chromiumPage == nil ? "webkit" : "chromium") }
        var drawn: [String: JSONValue] = [:]
        for (column, host) in hosts { drawn[column.rawValue] = .number(Double(host.count)) }
        return [
            "open": true, "window": .number(Double(window.windowNumber)), "stem": .string(scenario.stem),
            "scale": .number(window.backingScaleFactor), "backdrop": .string(scenario.backdrop.rawValue),
            "mode": .string(scenario.mode.rawValue), "key": .bool(window.isKeyWindow), "app_active": .bool(NSApp.isActive),
            "appearance": .string(appearance),
            "reduce_transparency": .bool(ReduceTransparency.shared.isEnabled),
            "increase_contrast": .bool(NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast),
            "engines": .object(engines), "host_glass": .object(drawn),
            "ready": .array(ready.map { .string($0.rawValue) }.sorted { ($0.stringValue ?? "") < ($1.stringValue ?? "") }),
            "liquid_glass": .bool(Glass.isLiquidGlassAvailable),
            "desktop_picture": .bool(picture != nil),
            "page_windows": pageWindows(in: window),
        ]
    }

    /// Each page's view rect on screen beside its child windows' frames (a Chromium page draws in a child window
    /// the Chromium fork places), so a page drawn off its view's pixels names the offset.
    func pageWindows(in window: NSWindow) -> JSONValue {
        func rect(_ r: CGRect) -> JSONValue { .array([r.minX, r.minY, r.width, r.height].map { .number($0) }) }
        var views: [String: JSONValue] = [:]
        for (column, page) in pages { views[column.rawValue] = rect(window.convertToScreen(page.convert(page.bounds, to: nil))) }
        return ["views": .object(views), "children": .array((window.childWindows ?? []).map { rect($0.frame) })]
    }

    var appearance: String {
        window?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? "dark" : "light"
    }

    func close() {
        window?.orderOut(nil)
        window?.close()
        window = nil
        pages = [:]
        hosts = [:]
        backdropView = nil
        nativeLayer = nil
        menuRowView = nil

        ready = []
    }

    /// Waits until `done` holds or `limit` passes, woken by the pages' reports and one deadline.
    func wait(until done: () -> Bool, limit: Duration) async {
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

    /// Waits until `done` holds or `limit` passes, checking every 50 ms: the app's activation and key state have
    /// no report of the playground's own to wake on (a debug measure, never a person's).
    private func poll(until done: () -> Bool, limit: Duration) async {
        let end = ContinuousClock.now + limit
        while !done(), ContinuousClock.now < end {
            await wait(until: { false }, limit: .milliseconds(50))
        }
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
        let stage = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: stage, styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Liquid Glass Parity"
        window.isReleasedWhenClosed = false
        window.setAccessibilityIdentifier("cmux.glassParity")
        let root = GlassParityFlippedView(frame: stage)
        // Layer-backed, so the backdrop draws into its own layer under the web views (in window-backing
        // drawing AppKit skipped it under them, opaque to it, and the glass sampled nothing).
        root.wantsLayer = true
        window.contentView = root
        let backdrop = GlassParityBackdropView(stage: stage)
        root.addSubview(backdrop)
        backdropView = backdrop
        let native = GlassParityFlippedView(frame: stage)
        native.wantsLayer = true
        for kind in Kind.allCases { native.addSubview(nativeSurface(kind)) }
        root.addSubview(native)
        nativeLayer = native
        for column in [Column.webkit, .chromium] {
            let host = GlassParityHostLayer(frame: stage)
            root.addSubview(host)
            hosts[column] = host
            let provider = GlassParityProvider(playground: self, column: column)
            let options = column == .webkit ? PageEngineOptions(requiresWebKit: .transparentOverlay) : .standard
            guard let page = PageWebView(descriptor: .glassParity, routes: [PageRoute(prefix: "cmux.glass_parity.", provider: provider)],
                                         options: options) else { continue }
            page.followsUIScale = false
            page.frame = stage
            root.addSubview(page)
            pages[column] = page
        }
        window.center()
        return window
    }

    /// The App's own surface for `kind`, as its native UI draws that role, with the same text.
    private func nativeSurface(_ kind: Kind) -> NSView {
        let radius = Self.radius(kind)
        let surface: OverlaySurfaceView = switch kind {
        case .menu: Glass.makeMenuPanel(cornerRadius: radius, interactive: false)
        // The native popovers' one transient material (the palette, page info, which-key).
        case .popover, .card: Glass.makeOverlayPanel(cornerRadius: radius, interactive: false, tone: .neutralGlass(.transient))
        // The tooltip window's whole surface: its glass, legibility tint and shadow (TooltipPanel).
        case .tooltip: Glass.makeTooltipGlass(cornerRadius: radius)
        case .dialog: Glass.makeSurface(.sheet, cornerRadius: radius, interactive: false)
        case .toast: Glass.makeSurface(.toast, cornerRadius: radius, interactive: false)
        // Docked glass (the tab strip's, a drag ghost's): the theme's glass at the chrome level's tint.
        case .chrome: Self.chromeGlass(cornerRadius: radius)
        }
        surface.translatesAutoresizingMaskIntoConstraints = true
        surface.frame = Self.surfaceRect(kind)
        // Pinned to the content view: it is laid out later, and autoresizing from its empty first frame
        // pushed the labels out of the surface.
        if kind == .menu {
            let row = GlassParityRowFill(frame: CGRect(origin: .zero, size: surface.frame.size), row: Self.menuRow, radius: Self.menuRowRadius)
            row.state = scenario.row
            row.translatesAutoresizingMaskIntoConstraints = false
            surface.contentView.addSubview(row)
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: surface.contentView.leadingAnchor),
                row.trailingAnchor.constraint(equalTo: surface.contentView.trailingAnchor),
                row.topAnchor.constraint(equalTo: surface.contentView.topAnchor),
                row.bottomAnchor.constraint(equalTo: surface.contentView.bottomAnchor),
            ])
            menuRowView = row
        }
        let text = GlassParityTextView(frame: CGRect(origin: .zero, size: surface.frame.size), title: Self.title(kind), detail: Self.detail(kind),
                                       smoothing: scenario.text != .flat)
        text.translatesAutoresizingMaskIntoConstraints = false
        surface.contentView.addSubview(text)
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: surface.contentView.leadingAnchor),
            text.trailingAnchor.constraint(equalTo: surface.contentView.trailingAnchor),
            text.topAnchor.constraint(equalTo: surface.contentView.topAnchor),
            text.bottomAnchor.constraint(equalTo: surface.contentView.bottomAnchor),
        ])
        return surface
    }

    /// Docked glass as the native chrome draws it (the tab strip's, a drag ghost's): the theme's glass
    /// at the chrome level's tint (``GlassLevel/chrome``).
    private static func chromeGlass(cornerRadius: CGFloat) -> OverlaySurfaceView {
        let surface = Glass.makeOverlayPanel(cornerRadius: cornerRadius, interactive: false)
        surface.tintLevel = .chrome
        return surface
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

    /// `debug.glass_parity {backdrop?, mode?, color?, opacity?, offset?, active?, row?, scale?, measure?, dir?,
    /// animate?, column?, close?}` (`animate`: seconds of a moving backdrop under `column`'s glass alone) (the App routes it here): opens or reconfigures the playground (``show(_:scale:)``; a key
    /// left out keeps its value) and, with `measure`, captures every renderer and diffs them into `dir`
    /// (default a folder in the temporary directory). `close` closes it.
    public func handle(_ params: [String: JSONValue], capture: ([String: JSONValue]) async -> JSONValue) async -> JSONValue {
        if params["close"]?.boolValue == true {
            close()
            return ["open": false]
        }
        var next = scenario
        if let name = params["backdrop"]?.stringValue {
            guard let backdrop = Backdrop(rawValue: name) else { return ["error": .string("unknown backdrop \(name)")] }
            next.backdrop = backdrop
        }
        if let name = params["mode"]?.stringValue {
            guard let mode = Mode(rawValue: name) else { return ["error": .string("unknown mode \(name)")] }
            next.mode = mode
        }
        if let hex = params["color"]?.stringValue {
            guard let value = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16), value <= 0xFFFFFF else {
                return ["error": .string("color must be RRGGBB")]
            }
            next.color = value
        }
        if let opacity = params["opacity"]?.doubleValue { next.opacity = CGFloat(min(max(opacity, 0), 1)) }
        if let offset = params["offset"]?.doubleValue { next.offset = CGFloat(min(max(offset, -200), 200)) }
        if let active = params["active"]?.boolValue { next.active = active }
        if let name = params["row"]?.stringValue {
            guard let row = RowState(rawValue: name) else { return ["error": .string("unknown row \(name)")] }
            next.row = row
        }
        if let name = params["text"]?.stringValue {
            guard let text = TextRendering(rawValue: name) else { return ["error": .string("unknown text \(name)")] }
            next.text = text
        }
        let scale = params["scale"]?.doubleValue.map { CGFloat($0) }
        let shown = await show(next, scale: scale)
        if let seconds = params["animate"]?.doubleValue {
            var only: Column?
            if let name = params["column"]?.stringValue {
                guard let column = Column(rawValue: name) else { return ["error": .string("unknown column \(name)")] }
                only = column
            }
            return await animate(seconds: min(max(seconds, 0.5), 20), only: only)
        }
        guard params["measure"]?.boolValue == true else { return shown }
        let directory = params["dir"]?.stringValue.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appending(path: "glass-parity", directoryHint: .isDirectory)
        return await measure(into: directory, capture: capture)
    }
}
#endif
