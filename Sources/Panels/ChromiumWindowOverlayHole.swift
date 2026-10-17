import AppKit
import CmuxBrowser
import CmuxCEF

/// Keeps one window-level overlay (the command palette) visible above the
/// window's Chromium pages.
///
/// A Chromium page is a child window ordered above the whole main window, so
/// an overlay drawn in the main window's view tree (not in the page's own
/// panel, which `BrowserPageOverlayCoordinator` handles) would show under the
/// page while still taking the keyboard. While active, this publishes the
/// overlay's frame as holes in every page of the window
/// (`CEFWindowOcclusion`), notched at its rounded corners so the page shows
/// there (design spec §0.9). It follows the overlay on every update cycle of
/// the window (one rect conversion per event) and costs nothing in a window
/// without a Chromium page.
///
/// Reference: cmux Next `CmuxNextApp/Windows/WindowOverlayLayer.swift`.
@MainActor
final class ChromiumWindowOverlayHole {
    private let source: String
    private let cornerRadius: CGFloat
    private let rectInWindow: @MainActor () -> CGRect?
    private let refreshNotifications: [Notification.Name]
    private weak var window: NSWindow?
    private var observers: [any NSObjectProtocol] = []

    /// - Parameters:
    ///   - source: The overlay's name among the window's hole sources.
    ///   - cornerRadius: The overlay's corner radius (notched hole).
    ///   - refreshNotifications: Posted when the overlay's frame changes outside an event
    ///     (its first layout after it opened): the hole follows at once.
    ///   - rectInWindow: The overlay's frame in window coordinates, nil while it is not shown.
    init(
        source: String,
        cornerRadius: CGFloat,
        refreshNotifications: [Notification.Name] = [],
        rectInWindow: @escaping @MainActor () -> CGRect?
    ) {
        self.source = source
        self.cornerRadius = cornerRadius
        self.refreshNotifications = refreshNotifications
        self.rectInWindow = rectInWindow
    }

    deinit {
        guard Thread.isMainThread else { return }
        MainActor.assumeIsolated {
            observers.forEach(NotificationCenter.default.removeObserver)
        }
    }

    /// The overlay shows in `window`: its pages leave a hole for it until ``deactivate()``.
    func activate(in window: NSWindow) {
        if self.window !== window {
            deactivate()
            self.window = window
        }
        if observers.isEmpty {
            let center = NotificationCenter.default
            observers.append(center.addObserver(
                forName: NSWindow.didUpdateNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.sync() }
            })
            for name in refreshNotifications {
                observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.sync() }
                })
            }
        }
        sync()
    }

    /// The overlay hid: the pages close its hole.
    func deactivate() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        if let window { CEFWindowOcclusion.existing(for: window)?.setRects([], for: source) }
        window = nil
    }

    private func sync() {
        guard let window, let registry = CEFWindowOcclusion.existing(for: window) else { return }
        let holes = rectInWindow().map {
            Self.holes(for: $0, cornerRadius: cornerRadius, windowSize: window.frame.size)
        } ?? []
        registry.setRects(holes, for: source)
    }

    /// The overlay's hole in window coordinates: non-overlapping rects that
    /// leave its rounded corners to the page, clipped to the window.
    static func holes(for rect: CGRect, cornerRadius: CGFloat, windowSize: CGSize) -> [CGRect] {
        BrowserPageOcclusionPlan(
            contentBounds: CGRect(origin: .zero, size: windowSize),
            overlays: [BrowserPageOcclusionPlan.Overlay(rect: rect, cornerRadius: cornerRadius)]
        ).holes
    }
}

/// One-shot holes in a window's Chromium pages for window-level UI that
/// tracks itself (a resizer band while the pointer is in it).
enum ChromiumWindowHoles {
    /// Replaces `source`'s holes (window coordinates) in `window`'s pages; a
    /// no-op in a window without a Chromium page.
    @MainActor
    static func set(_ rects: [CGRect], for source: String, in window: NSWindow?) {
        guard let window, let registry = CEFWindowOcclusion.existing(for: window) else { return }
        registry.setRects(rects, for: source)
    }
}
