public import AppKit
public import Combine

/// Keeps a browser panel's overlays (find bar, permission bar, crash page,
/// notices) visible above its page, whatever engine draws the page.
///
/// A WebKit page is a view in the panel, so overlays drawn above it in the
/// view tree simply show. A Chromium page is a child window that the fork
/// orders above the whole main window, so every view of the panel is under
/// it. Two placements fix that, as in cmux Next:
///
/// - **Occluding** overlays (bars and full-page cards that take the keyboard:
///   find bar, permission bar, crash and error pages) stay in the panel's
///   view tree; the page leaves a hole where each one shows
///   (`BrowserPageOcclusionHosting`), so the keyboard and the mouse reach
///   them as over a WebKit page and they never take key status.
/// - **Floating** overlays (rounded cards over the live page: the engine
///   notice) draw in a small non-activating child panel ordered above the
///   page windows, so their corners and material show the page under them.
///
/// Mount points are host-agnostic SwiftUI (`browserPageOccluding(_:)`,
/// `BrowserPageFloatingOverlay`); with no child-window page attached the
/// coordinator does nothing and every overlay renders in place.
///
/// The coordinator follows pane moves, resizes and workspace switches by
/// recomputing on the main window's update cycle (one pass per event, a few
/// rect conversions) while overlays are registered; a hidden overlay or a
/// page out of the window makes no hole.
///
/// References: cmux Next `CmuxNextBrowser/UI/BrowserChromeView.swift`
/// (`updateOcclusion`), `UI/PageFloatingOverlays.swift`,
/// `CmuxNextDesign/Overlay/WindowOverlayHost.swift` (order above page windows);
/// design spec §4, §8, §9.
@MainActor
public final class BrowserPageOverlayCoordinator: ObservableObject {
    /// Whether floating overlays draw in child panels (a child-window page
    /// is attached). SwiftUI mount points switch on it.
    @Published public private(set) var hostsFloatingOverlaysInPanels = false

    private weak var contentView: NSView?
    private weak var occlusionTarget: (any BrowserPageOcclusionHosting)?
    private var occludingAnchors: [String: WeakView] = [:]
    private var floatingOverlays: [String: FloatingOverlay] = [:]
    private var updateObserver: (any NSObjectProtocol)?
    private weak var observedWindow: NSWindow?
    /// The floating placement last asked for (published on the next turn).
    private var pendingFloatingPlacement = false

    public init() {}

    deinit {
        // Released on the main thread by its panel; panels must not outlive it.
        guard Thread.isMainThread else { return }
        MainActor.assumeIsolated {
            if let updateObserver { NotificationCenter.default.removeObserver(updateObserver) }
            for overlay in floatingOverlays.values { overlay.panel.detach() }
        }
    }

    // MARK: Page

    /// Attaches the page: `contentView` is what the panel hosts for it and
    /// `target` receives the holes. Pass nil `target` for an in-view
    /// (WebKit) page: overlays then render in place.
    public func attach(contentView: NSView?, target: (any BrowserPageOcclusionHosting)?) {
        self.contentView = contentView
        if let occlusionTarget, occlusionTarget !== target { occlusionTarget.pageOcclusionRects = [] }
        occlusionTarget = target
        publishFloatingPlacement(target != nil && contentView != nil)
        update()
    }

    /// Publishes where floating overlays draw. Attaching runs inside SwiftUI
    /// view updates (`makeNSView` / `updateNSView`), where publishing is not
    /// allowed, so the change lands on the next main-queue turn.
    private func publishFloatingPlacement(_ inPanels: Bool) {
        guard pendingFloatingPlacement != inPanels else { return }
        pendingFloatingPlacement = inPanels
        DispatchQueue.main.async { [weak self] in
            guard let self, self.pendingFloatingPlacement == inPanels,
                  self.hostsFloatingOverlaysInPanels != inPanels else { return }
            self.hostsFloatingOverlaysInPanels = inPanels
        }
    }

    /// Detaches the page (the panel closes or swaps its page).
    public func detach() {
        attach(contentView: nil, target: nil)
    }

    // MARK: Occluding overlays

    /// `anchor` shows an occluding overlay (its frame is the overlay's frame).
    public func registerOccluding(_ anchor: NSView, id: String) {
        occludingAnchors[id] = WeakView(view: anchor)
        update()
    }

    public func unregisterOccluding(id: String) {
        guard occludingAnchors.removeValue(forKey: id) != nil else { return }
        update()
    }

    // MARK: Floating overlays

    /// Shows `content` in a child panel over `anchor`'s frame while a
    /// child-window page is attached.
    public func registerFloating(_ anchor: NSView, id: String, content: NSView) {
        if let existing = floatingOverlays[id], existing.panel.contentView === content {
            existing.anchor.view = anchor
        } else {
            floatingOverlays[id]?.panel.detach()
            floatingOverlays[id] = FloatingOverlay(anchor: WeakView(view: anchor), panel: BrowserPageFloatingOverlayPanel(content: content))
        }
        update()
    }

    public func unregisterFloating(id: String) {
        guard let overlay = floatingOverlays.removeValue(forKey: id) else { return }
        overlay.panel.detach()
        update()
    }

    // MARK: Sync

    /// Recomputes the page's holes and the floating panels' frames. Called by
    /// the anchors on layout, window and visibility changes, and on every
    /// update cycle of the main window while overlays are registered.
    public func update() {
        occludingAnchors = occludingAnchors.filter { $0.value.view != nil }
        floatingOverlays = floatingOverlays.filter { _, overlay in
            if overlay.anchor.view == nil { overlay.panel.detach(); return false }
            return true
        }
        observeWindowUpdates()
        guard let contentView, let window = contentView.window, let occlusionTarget,
              !contentView.isHiddenOrHasHiddenAncestor else {
            occlusionTarget?.pageOcclusionRects = []
            for overlay in floatingOverlays.values { overlay.panel.detach() }
            return
        }
        // Holes are in the content view's own coordinates (AppKit handles a
        // flipped view or a bounds offset).
        let plan = BrowserPageOcclusionPlan(
            contentBounds: contentView.bounds,
            overlayRects: occludingAnchors.values.compactMap { anchor in
                Self.shownRectInWindow(anchor.view, window: window).map { contentView.convert($0, from: nil) }
            }
        )
        let holes = plan.holes
        if occlusionTarget.pageOcclusionRects != holes { occlusionTarget.pageOcclusionRects = holes }
        let contentRect = contentView.convert(contentView.bounds, to: nil)
        for overlay in floatingOverlays.values {
            guard window.isVisible,
                  let rect = Self.shownRectInWindow(overlay.anchor.view, window: window)?.intersection(contentRect),
                  !rect.isNull, !rect.isEmpty else {
                overlay.panel.detach()
                continue
            }
            overlay.panel.place(over: window.convertToScreen(rect), in: window)
        }
    }

    /// The overlay's frame in window coordinates, nil when it is not shown.
    private static func shownRectInWindow(_ view: NSView?, window: NSWindow) -> CGRect? {
        guard let view, view.window === window, !view.isHiddenOrHasHiddenAncestor, view.alphaValue > 0.01 else {
            return nil
        }
        let rect = view.convert(view.bounds, to: nil)
        return rect.isEmpty ? nil : rect
    }

    /// Follows the main window's update cycle while anything is registered
    /// and a child-window page is attached; stops otherwise.
    private func observeWindowUpdates() {
        let wanted = occlusionTarget != nil && (!occludingAnchors.isEmpty || !floatingOverlays.isEmpty)
        let window = wanted ? contentView?.window : nil
        guard window !== observedWindow || (window == nil) != (updateObserver == nil) else { return }
        if let updateObserver { NotificationCenter.default.removeObserver(updateObserver) }
        updateObserver = nil
        observedWindow = window
        guard let window else { return }
        updateObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didUpdateNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
    }

    private final class WeakView {
        weak var view: NSView?
        init(view: NSView) { self.view = view }
    }

    private struct FloatingOverlay {
        let anchor: WeakView
        let panel: BrowserPageFloatingOverlayPanel
    }

    #if DEBUG
    /// Registered occluding overlay ids (tests, diagnostics).
    var occludingIDs: Set<String> { Set(occludingAnchors.keys) }
    /// Floating overlay panels currently attached to a window, by id.
    func floatingPanel(id: String) -> NSPanel? { floatingOverlays[id]?.panel }
    #endif
}
