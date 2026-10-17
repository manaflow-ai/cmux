public import AppKit

/// Native UI of a whole window that must show above, or get the mouse over,
/// every Chromium page in it: the command palette, a divider's grab band
/// under the pointer.
///
/// A Chromium page is a child window ordered above the whole main window, so
/// a view of the main window (not of the page's own panel) is under every
/// page. Its owner publishes the view's rects here in window coordinates, and
/// every ``CEFHostView`` in the window adds them to its holes on the fork's
/// next geometry read (`-cmuxOcclusionRects`), so the view shows and takes
/// the mouse there as it does over a WebKit page (design spec §0.9).
///
/// Holes published by one source must not overlap each other (the fork masks
/// with even-odd rules); the host view joins the sources' holes with its own
/// into non-overlapping rects.
///
/// Reference: cmux Next `CmuxNextApp/Windows/WindowOverlayLayer.swift`
/// (`interactiveRects`) and `ShellWindow.browserOcclusionRectsInWindow`.
@MainActor
public final class CEFWindowOcclusion {
    /// Posted with the window as object when its rects change.
    public static let didChangeNotification = Notification.Name("cmux.CEFWindowOcclusion.didChange")

    private static let registries = NSMapTable<NSWindow, CEFWindowOcclusion>.weakToStrongObjects()

    /// The window's registry, made on first use.
    public static func registry(for window: NSWindow) -> CEFWindowOcclusion {
        if let existing = registries.object(forKey: window) { return existing }
        let registry = CEFWindowOcclusion(window: window)
        registries.setObject(registry, forKey: window)
        return registry
    }

    /// The window's registry, nil when no page or source ever used it (a
    /// window with no Chromium page pays nothing).
    public static func existing(for window: NSWindow) -> CEFWindowOcclusion? {
        registries.object(forKey: window)
    }

    private weak var window: NSWindow?
    private var rectsBySource: [String: [CGRect]] = [:]
    private let hosts = NSHashTable<CEFHostView>.weakObjects()

    private init(window: NSWindow) {
        self.window = window
    }

    /// Every source's rects, in window coordinates.
    public private(set) var rectsInWindow: [CGRect] = []

    /// Replaces `source`'s rects (window coordinates). Setting equal rects
    /// costs nothing; a change makes every page of the window re-read its holes.
    public func setRects(_ rects: [CGRect], for source: String) {
        let kept = rects.filter { !$0.isNull && !$0.isEmpty }
        guard (rectsBySource[source] ?? []) != kept else { return }
        rectsBySource[source] = kept.isEmpty ? nil : kept
        rectsInWindow = rectsBySource.keys.sorted().flatMap { rectsBySource[$0] ?? [] }
        guard let window else { return }
        NotificationCenter.default.post(name: Self.didChangeNotification, object: window)
    }

    /// The rects `source` published.
    public func rects(for source: String) -> [CGRect] {
        rectsBySource[source] ?? []
    }

    /// The page host views in the window (pages and docked DevTools).
    public var hostViews: [CEFHostView] {
        hosts.allObjects.filter { $0.window === window }
    }

    func add(_ host: CEFHostView) { hosts.add(host) }
    func remove(_ host: CEFHostView) { hosts.remove(host) }
}
