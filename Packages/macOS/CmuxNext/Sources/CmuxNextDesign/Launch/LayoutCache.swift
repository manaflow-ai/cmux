public import AppKit
import CCmuxLayoutCacheFFI

// Every window's last computed layout, kept across restarts so a launch draws it already placed
// (Leo, 2026-11-24: "we're recalculating positionings of things. but they can be stored. we can
// cache that shit. for restarts, for anything."). The rules (read, validity against the build and
// the displays, reconcile, the write coalescer) are Rust's, cmux-tui/crates/cmux-layout-cache; these
// are its JSON model's Swift mirror and thin calls into its C ABI. Swift gathers and applies only.

/// `Rect` (cmux-layout-cache src/model.rs): AppKit global points for window frames, top-left
/// origin content points inside a window.
public struct LayoutCacheRect: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    public init(_ rect: CGRect) {
        self.init(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
    }

    public var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

public struct LayoutCacheDisplay: Codable, Hashable, Sendable {
    public var id: UInt32
    public var frame: LayoutCacheRect
    public var backingScale: Double

    public init(id: UInt32, frame: LayoutCacheRect, backingScale: Double) {
        self.id = id; self.frame = frame; self.backingScale = backingScale
    }

    /// Every screen now, as the cache and `usable` name them.
    @MainActor public static func current() -> [LayoutCacheDisplay] {
        NSScreen.screens.map { screen in
            LayoutCacheDisplay(id: LayoutCacheDisplay.id(of: screen), frame: LayoutCacheRect(screen.frame),
                               backingScale: screen.backingScaleFactor)
        }
    }

    /// The screen's CGDirectDisplayID, 0 when AppKit does not say.
    @MainActor public static func id(of screen: NSScreen?) -> UInt32 {
        (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}

public enum LayoutCacheAppearance: String, Codable, Sendable {
    case light, dark
}

public struct LayoutCacheTheme: Codable, Hashable, Sendable {
    /// The window backdrop's colour; its alpha is the backdrop opacity.
    public var backgroundRgba: [UInt8]
    public var barRgba: [UInt8]
    public var accentRgba: [UInt8]?
    public var fontFamily: String?
    public var fontSize: Double?

    public init(backgroundRgba: [UInt8], barRgba: [UInt8], accentRgba: [UInt8]? = nil, fontFamily: String? = nil, fontSize: Double? = nil) {
        self.backgroundRgba = backgroundRgba; self.barRgba = barRgba; self.accentRgba = accentRgba
        self.fontFamily = fontFamily; self.fontSize = fontSize
    }

    /// A 0-to-1 colour component as a byte.
    public static func byte(_ component: Double) -> UInt8 { UInt8(exactly: (min(1, max(0, component)) * 255).rounded()) ?? 0 }

    /// The backdrop opacity, 0 to 1 (nil when the cache has no colour).
    public var backdropOpacity: Double? { backgroundRgba.count == 4 ? Double(backgroundRgba[3]) / 255 : nil }
}

public struct LayoutCacheRowHeight: Codable, Hashable, Sendable {
    public var id: String
    public var height: Double

    public init(id: String, height: Double) { self.id = id; self.height = height }
}

public struct LayoutCacheSidebar: Codable, Hashable, Sendable {
    public var width: Double
    public var collapsed: Bool
    public var scrollY: Double
    public var rowHeights: [LayoutCacheRowHeight]

    public init(width: Double, collapsed: Bool, scrollY: Double = 0, rowHeights: [LayoutCacheRowHeight] = []) {
        self.width = width; self.collapsed = collapsed; self.scrollY = scrollY; self.rowHeights = rowHeights
    }
}

public struct LayoutCacheTabSlot: Codable, Hashable, Sendable {
    public var id: String
    public var x: Double
    public var width: Double

    public init(id: String, x: Double, width: Double) { self.id = id; self.x = x; self.width = width }
}

public struct LayoutCacheScroll: Codable, Hashable, Sendable {
    public var offsetY: Double
    public var contentHeight: Double

    public init(offsetY: Double, contentHeight: Double) { self.offsetY = offsetY; self.contentHeight = contentHeight }
}

/// `PaneKind`; a kind this app does not know reads as `other` (as in Rust).
public enum LayoutCachePaneKind: String, Codable, Sendable {
    case terminal, chat, browser, home, other

    public init(from decoder: any Decoder) throws {
        self = LayoutCachePaneKind(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .other
    }
}

public struct LayoutCacheLeaf: Codable, Hashable, Sendable {
    public var paneId: String
    public var kind: LayoutCachePaneKind
    /// Content points, top-left origin, in the window's content view.
    public var frame: LayoutCacheRect
    public var scroll: LayoutCacheScroll?

    public init(paneId: String, kind: LayoutCachePaneKind, frame: LayoutCacheRect, scroll: LayoutCacheScroll? = nil) {
        self.paneId = paneId; self.kind = kind; self.frame = frame; self.scroll = scroll
    }
}

/// `PaneNode`: `{"type": "split", axis, fractions, children}` or `{"type": "leaf", pane_id, ...}`.
public indirect enum LayoutCachePaneNode: Codable, Hashable, Sendable {
    /// `horizontal`: children side by side ("h"); else stacked ("v"). `fractions` sum to 1.
    case split(horizontal: Bool, fractions: [Double], children: [LayoutCachePaneNode])
    case leaf(LayoutCacheLeaf)

    private enum Keys: String, CodingKey { case type, axis, fractions, children }

    public init(from decoder: any Decoder) throws {
        let keys = try decoder.container(keyedBy: Keys.self)
        if try keys.decode(String.self, forKey: .type) == "split" {
            self = .split(horizontal: (try keys.decodeIfPresent(String.self, forKey: .axis) ?? "h") == "h",
                          fractions: try keys.decodeIfPresent([Double].self, forKey: .fractions) ?? [],
                          children: try keys.decodeIfPresent([LayoutCachePaneNode].self, forKey: .children) ?? [])
        } else {
            self = .leaf(try LayoutCacheLeaf(from: decoder))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case let .split(horizontal, fractions, children):
            var keys = encoder.container(keyedBy: Keys.self)
            try keys.encode("split", forKey: .type)
            try keys.encode(horizontal ? "h" : "v", forKey: .axis)
            try keys.encode(fractions, forKey: .fractions)
            try keys.encode(children, forKey: .children)
        case let .leaf(leaf):
            try leaf.encode(to: encoder)
            var keys = encoder.container(keyedBy: Keys.self)
            try keys.encode("leaf", forKey: .type)
        }
    }

    /// Every leaf, in tree order.
    public var leaves: [LayoutCacheLeaf] {
        switch self {
        case let .leaf(leaf): [leaf]
        case let .split(_, _, children): children.flatMap(\.leaves)
        }
    }
}

public struct LayoutCacheWindow: Codable, Hashable, Sendable {
    public var id: String
    /// AppKit global points.
    public var frame: LayoutCacheRect
    public var displayId: UInt32
    public var backingScale: Double
    public var fullscreen: Bool
    /// Window opacity, 0 to 1.
    public var alpha: Double
    public var appearance: LayoutCacheAppearance
    public var theme: LayoutCacheTheme
    public var sidebar: LayoutCacheSidebar
    public var workspaceId: String
    public var tabId: String
    public var tabStrip: [LayoutCacheTabSlot]
    public var panes: LayoutCachePaneNode?

    public init(id: String, frame: LayoutCacheRect, displayId: UInt32, backingScale: Double, fullscreen: Bool, alpha: Double,
                appearance: LayoutCacheAppearance, theme: LayoutCacheTheme, sidebar: LayoutCacheSidebar, workspaceId: String,
                tabId: String, tabStrip: [LayoutCacheTabSlot], panes: LayoutCachePaneNode?) {
        self.id = id; self.frame = frame; self.displayId = displayId; self.backingScale = backingScale
        self.fullscreen = fullscreen; self.alpha = alpha; self.appearance = appearance; self.theme = theme
        self.sidebar = sidebar; self.workspaceId = workspaceId; self.tabId = tabId; self.tabStrip = tabStrip; self.panes = panes
    }
}

extension LayoutCacheWindow {
    /// `window` as it stands: frame, display, scale, fullscreen, alpha, appearance. `surface` is the
    /// theme's surface colour (0 to 1 components; its alpha is the backdrop opacity). TODO: the tab
    /// strip's slots and the selected tab (the strip keeps no x/width yet), the sidebar's scroll.
    @MainActor public static func gather(_ window: NSWindow, id: String, surface: [Double], sidebarWidth: Double,
                                         sidebarCollapsed: Bool, workspaceId: String, panes: LayoutCachePaneNode?) -> LayoutCacheWindow {
        let rgba = surface.map(LayoutCacheTheme.byte)
        let dark = window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return LayoutCacheWindow(
            id: id, frame: LayoutCacheRect(window.frame), displayId: LayoutCacheDisplay.id(of: window.screen),
            backingScale: window.backingScaleFactor, fullscreen: window.styleMask.contains(.fullScreen), alpha: window.alphaValue,
            appearance: dark ? .dark : .light, theme: LayoutCacheTheme(backgroundRgba: rgba, barRgba: rgba),
            sidebar: LayoutCacheSidebar(width: sidebarWidth, collapsed: sidebarCollapsed),
            workspaceId: workspaceId, tabId: "", tabStrip: [], panes: panes)
    }

    /// `view`'s frame in `window`'s content view, top-left origin (a leaf's `frame`); nil off window.
    @MainActor public static func contentFrame(of view: NSView, in window: NSWindow?) -> CGRect? {
        guard let root = window?.contentView, view.window === window else { return nil }
        var frame = root.convert(view.bounds, from: view)
        if !root.isFlipped { frame.origin.y = root.bounds.height - frame.maxY }
        return frame
    }

    /// Sets `window`'s frame only when it differs: a window already at its place (stage 0's or the
    /// cache's) is not moved or redrawn. True when it moved.
    @MainActor @discardableResult public static func place(_ window: NSWindow?, at frame: CGRect) -> Bool {
        guard let window, window.frame.integral != frame.integral else { return false }
        window.setFrame(frame, display: true)
        return true
    }
}

public struct LayoutCacheDocument: Codable, Hashable, Sendable {
    /// cmux-layout-cache `FORMAT_VERSION`; Rust drops any other.
    public static let formatVersion: UInt32 = 1
    public var version: UInt32
    /// The build that drew `last_content` pictures (`LaunchShellPaths.build`).
    public var buildKey: String
    public var writtenAtMs: UInt64
    public var displays: [LayoutCacheDisplay]
    public var windows: [LayoutCacheWindow]

    public init(buildKey: String, writtenAtMs: UInt64 = 0, displays: [LayoutCacheDisplay], windows: [LayoutCacheWindow]) {
        version = Self.formatVersion; self.buildKey = buildKey; self.writtenAtMs = writtenAtMs
        self.displays = displays; self.windows = windows
    }

    /// `windows` (front first) on this build and the displays now, as JSON for `LayoutCacheWriter`.
    @MainActor public static func json(_ windows: [LayoutCacheWindow]) -> String? {
        LayoutCacheFFI.json(LayoutCacheDocument(buildKey: LaunchShellPaths.build(info: Bundle.main.infoDictionary ?? [:]),
                                                displays: LayoutCacheDisplay.current(), windows: windows))
    }
}

/// `Usable`: which windows' geometry applies this launch, and where each goes.
public struct LayoutCacheUsable: Codable, Sendable {
    public struct Placement: Codable, Sendable {
        public var id: String
        public var frame: LayoutCacheRect
        public var displayId: UInt32
    }

    public struct Reason: Codable, Sendable {
        public var windowId: String
        public var kind: String
        public var paneId: String?
    }

    public var windows: [String]
    public var frames: [Placement]
    public var content: [String]
    public var reasons: [Reason]
}

/// `Applied` (reconcile): the cached tree fitted to the live one.
public struct LayoutCacheApplied: Codable, Sendable {
    public struct Transition: Codable, Sendable {
        public var kind: String
        public var panes: [String]
    }

    public struct Moved: Codable, Sendable {
        public var paneId: String
        public var from: LayoutCacheRect
        public var to: LayoutCacheRect
    }

    public var node: LayoutCachePaneNode
    /// Empty when the cache matched exactly: the first frame is the final frame.
    public var transitions: [Transition]
    public var moved: [Moved]
}

/// `LiveTree`'s `root`: the split structure the daemon says exists.
public indirect enum LayoutCacheLiveNode: Encodable, Sendable {
    case split(horizontal: Bool, children: [LayoutCacheLiveNode])
    case leaf(paneId: String, kind: LayoutCachePaneKind)

    private enum Keys: String, CodingKey { case type, axis, children, paneId, kind }

    public func encode(to encoder: any Encoder) throws {
        var keys = encoder.container(keyedBy: Keys.self)
        switch self {
        case let .split(horizontal, children):
            try keys.encode("split", forKey: .type)
            try keys.encode(horizontal ? "h" : "v", forKey: .axis)
            try keys.encode(children, forKey: .children)
        case let .leaf(paneId, kind):
            try keys.encode("leaf", forKey: .type)
            try keys.encode(paneId, forKey: .paneId)
            try keys.encode(kind, forKey: .kind)
        }
    }
}

public struct LayoutCacheLiveTree: Encodable, Sendable {
    public var panes: [String]
    public var root: LayoutCacheLiveNode?
    public var bounds: LayoutCacheRect?
    public var divider: Double

    public init(panes: [String], root: LayoutCacheLiveNode?, bounds: LayoutCacheRect?, divider: Double) {
        self.panes = panes; self.root = root; self.bounds = bounds; self.divider = divider
    }
}

/// `StripApplied` (reconcile_strip).
public struct LayoutCacheStripApplied: Codable, Sendable {
    public var tabs: [LayoutCacheTabSlot]
}

/// The C ABI's calls (include/cmux_layout_cache.h), JSON in and out, snake_case on the wire.
public struct LayoutCacheFFI {
    public init() {}
    public static func encoder() -> JSONEncoder {
        // main-actor-ok: the launch layout cache, one file Rust caps at 512 KiB, read once before the first window commits.
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        // main-actor-ok: the launch layout cache, one file Rust caps at 512 KiB, read once before the first window commits.
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    public static func json(_ value: some Encodable) -> String? {
        (try? encoder().encode(value)).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// A string the ABI returned, taken and freed.
    static func take(_ pointer: UnsafeMutablePointer<CChar>?) -> String? {
        guard let pointer else { return nil }
        defer { cmux_layout_cache_string_free(pointer) }
        return String(cString: pointer)
    }

    static func decode<T: Decodable>(_ type: T.Type, _ pointer: UnsafeMutablePointer<CChar>?) -> T? {
        take(pointer).flatMap { try? decoder().decode(type, from: Data($0.utf8)) }
    }

    /// `<support>/layout-cache/v1.json`, the app's Application Support folder (beside launch-record.bin).
    public static func path(support: URL) -> String? {
        take(cmux_layout_cache_path(support.path))
    }

    /// The cache at `path`, or nil (missing, too large, another version, garbage).
    public static func read(path: String) -> LayoutCacheDocument? {
        decode(LayoutCacheDocument.self, cmux_layout_cache_read(path))
    }

    public static func usable(_ cache: LayoutCacheDocument, build: String, displays: [LayoutCacheDisplay], nowMs: UInt64) -> LayoutCacheUsable? {
        struct Now: Encodable { var buildKey: String; var displays: [LayoutCacheDisplay]; var nowMs: UInt64 }
        guard let cacheJSON = json(cache), let nowJSON = json(Now(buildKey: build, displays: displays, nowMs: nowMs)) else { return nil }
        return decode(LayoutCacheUsable.self, cmux_layout_cache_usable(cacheJSON, nowJSON))
    }

    public static func reconcile(_ cached: LayoutCachePaneNode, live: LayoutCacheLiveTree) -> LayoutCacheApplied? {
        guard let cachedJSON = json(cached), let liveJSON = json(live) else { return nil }
        return decode(LayoutCacheApplied.self, cmux_layout_cache_reconcile(cachedJSON, liveJSON))
    }

    public static func reconcileStrip(_ cached: [LayoutCacheTabSlot], live: [String], defaultWidth: Double) -> LayoutCacheStripApplied? {
        guard let cachedJSON = json(cached), let liveJSON = json(live) else { return nil }
        return decode(LayoutCacheStripApplied.self, cmux_layout_cache_reconcile_strip(cachedJSON, liveJSON, defaultWidth))
    }

    /// Wall clock ms, for `usable`'s picture age.
    public static func wallClockMs() -> UInt64 { UInt64(exactly: (Date().timeIntervalSince1970 * 1000).rounded(.down)) ?? 0 }
}

/// The cache as this launch read it, gated by `usable`: only windows whose geometry applies on
/// the displays now are offered, at the frame Rust placed them.
public struct LayoutCacheLaunch: Sendable {
    public let document: LayoutCacheDocument
    public let usable: LayoutCacheUsable

    /// Reads and gates the cache in the app's support folder; nil when there is none or nothing applies.
    /// One ≤512 KiB file, before the first commit (`LaunchShell.prepare`).
    @MainActor public static func read(support: URL, build: String) -> LayoutCacheLaunch? {
        guard let path = LayoutCacheFFI.path(support: support), let document = LayoutCacheFFI.read(path: path),
              let usable = LayoutCacheFFI.usable(document, build: build, displays: LayoutCacheDisplay.current(),
                                                 nowMs: LayoutCacheFFI.wallClockMs()),
              !usable.windows.isEmpty else { return nil }
        return LayoutCacheLaunch(document: document, usable: usable)
    }

    /// The usable cached window `id`.
    public func window(_ id: String) -> LayoutCacheWindow? {
        guard usable.windows.contains(id) else { return nil }
        return document.windows.first { $0.id == id }
    }

    /// The cached window a new window `id` opens as: its own, else for the launch window (a new id
    /// standing for the front window) the front one.
    public func window(opening id: String, isLaunch: Bool) -> LayoutCacheWindow? {
        window(id) ?? (isLaunch ? front : nil)
    }

    /// The first usable window (the cache keeps the front window first).
    public var front: LayoutCacheWindow? { usable.windows.first.flatMap(window) }

    /// Where window `id` goes now (its cached frame, or Rust's clamp onto a display that exists).
    public func frame(for id: String) -> CGRect? {
        usable.frames.first { $0.id == id }?.frame.cgRect
    }
}
