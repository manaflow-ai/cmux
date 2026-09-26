import AppKit

/// One user-prompt boundary anchored to Ghostty's current absolute row space.
///
/// The marker captures the live-bottom viewport when the prompt-submit hook
/// arrives. Appended output leaves that row stable. If Ghostty later renumbers
/// bounded scrollback, the row-space revision changes and the marker expires
/// with the rows it referenced.
struct TerminalPromptScrollMarker: Equatable, Sendable {
    let topRow: UInt64
    let rowSpaceRevision: UInt64

    init?(geometry: NotificationScrollRestoreGeometry) {
        let scrollbar = geometry.scrollbar
        let visibleRows = min(scrollbar.total, scrollbar.len)
        guard visibleRows > 0 else { return nil }

        topRow = scrollbar.total - visibleRows
        rowSpaceRevision = geometry.rowSpaceRevision
    }

    /// Position in the scrollable track, where 0 is the oldest reachable
    /// viewport and 1 is the live bottom.
    func trackFraction(in geometry: NotificationScrollRestoreGeometry) -> CGFloat? {
        guard geometry.rowSpaceRevision == rowSpaceRevision else { return nil }

        let scrollbar = geometry.scrollbar
        let visibleRows = min(scrollbar.total, scrollbar.len)
        guard visibleRows > 0 else { return nil }

        let lastTopRow = scrollbar.total - visibleRows
        guard lastTopRow > 0, topRow <= lastTopRow else { return nil }
        return CGFloat(Double(topRow) / Double(lastTopRow))
    }
}

@MainActor
private final class TerminalPromptScrollMarkerOverlayView: NSView {
    weak var scroller: NSScroller?
    var onActivate: ((TerminalPromptScrollMarker) -> Void)?

    private var markers: [TerminalPromptScrollMarker] = []
    private var geometry: NotificationScrollRestoreGeometry?

    override var isOpaque: Bool { false }

    func update(
        markers: [TerminalPromptScrollMarker],
        geometry: NotificationScrollRestoreGeometry?
    ) {
        self.markers = markers
        self.geometry = geometry
        isHidden = markers.isEmpty || geometry == nil
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.controlAccentColor.setFill()
        for entry in markerEntries() where entry.rect.intersects(dirtyRect) {
            NSBezierPath(
                roundedRect: entry.rect,
                xRadius: entry.rect.height / 2,
                yRadius: entry.rect.height / 2
            ).fill()
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        marker(at: point) == nil ? nil : self
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let marker = marker(at: point) else { return }
        onActivate?(marker)
    }

    private func marker(at point: NSPoint) -> TerminalPromptScrollMarker? {
        markerEntries()
            .filter { $0.hitRect.contains(point) }
            .min { lhs, rhs in
                abs(lhs.rect.midY - point.y) < abs(rhs.rect.midY - point.y)
            }?
            .marker
    }

    private func markerEntries() -> [
        (marker: TerminalPromptScrollMarker, rect: NSRect, hitRect: NSRect)
    ] {
        guard let geometry else { return [] }
        return markers.compactMap { marker in
            guard let rect = markerRect(for: marker, geometry: geometry) else { return nil }
            return (
                marker: marker,
                rect: rect,
                hitRect: rect.insetBy(dx: -2, dy: -4)
            )
        }
    }

    private func markerRect(
        for marker: TerminalPromptScrollMarker,
        geometry: NotificationScrollRestoreGeometry
    ) -> NSRect? {
        guard let fraction = marker.trackFraction(in: geometry) else { return nil }

        let slot = scroller?.rect(for: .knobSlot) ?? bounds
        guard slot.width > 0, slot.height > 0 else { return nil }

        let markerHeight: CGFloat = min(3, slot.height)
        let markerWidth: CGFloat = max(2, min(slot.width, 8))
        let centerY = slot.maxY - (fraction * slot.height)
        let originY = min(
            max(centerY - markerHeight / 2, slot.minY),
            slot.maxY - markerHeight
        )

        return NSRect(
            x: slot.midX - markerWidth / 2,
            y: originY,
            width: markerWidth,
            height: markerHeight
        )
    }
}

/// Provides viewport plumbing while Ghostty owns terminal scrollback.
@MainActor
final class GhosttyScrollView: NSScrollView {
    weak var surfaceView: GhosttyNSView?

    private let promptMarkerOverlay = TerminalPromptScrollMarkerOverlayView(frame: .zero)
    private var promptScrollMarkers: [TerminalPromptScrollMarker] = []
    private var promptMarkerScrollbarObserver: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        // Bonsplit lays out the tab strip outside this viewport, so AppKit must not
        // infer another terminal-content inset from the window title bar.
        automaticallyAdjustsContentInsets = false
        contentInsets = NSEdgeInsetsZero

        promptMarkerOverlay.onActivate = { [weak self] marker in
            _ = self?.activatePromptScrollMarker(marker)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let promptMarkerScrollbarObserver {
            NotificationCenter.default.removeObserver(promptMarkerScrollbarObserver)
        }
    }

    // Keep keyboard routing on the terminal surface; this wrapper is viewport plumbing.
    override var acceptsFirstResponder: Bool { false }

    override func tile() {
        super.tile()
        installPromptMarkerOverlayIfNeeded()
        promptMarkerOverlay.needsDisplay = true
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surfaceView else {
            super.scrollWheel(with: event)
            return
        }

        // Route wheel gestures to the terminal surface so Ghostty handles scrollback.
        // Letting NSScrollView consume these events moves the wrapper viewport itself,
        // which causes pane-content drift instead of terminal scrollback movement.
        GhosttyNSView.focusLog("GhosttyScrollView.scrollWheel: surface scroll")
        if window?.firstResponder !== surfaceView {
            window?.makeFirstResponder(surfaceView)
        }
        surfaceView.scrollWheel(with: event)
    }

    func recordPromptScrollMarker() {
        guard let surfaceView,
              let geometry = surfaceView.authoritativeScrollbarGeometry(),
              let marker = TerminalPromptScrollMarker(geometry: geometry) else { return }

        promptScrollMarkers.removeAll {
            $0.rowSpaceRevision != geometry.rowSpaceRevision
        }
        promptScrollMarkers.append(marker)
        ensurePromptMarkerScrollbarObserver()
        refreshPromptMarkers(using: geometry)
    }

    private func ensurePromptMarkerScrollbarObserver() {
        guard promptMarkerScrollbarObserver == nil, let surfaceView else { return }
        promptMarkerScrollbarObserver = NotificationCenter.default.addObserver(
            forName: .ghosttyDidUpdateScrollbar,
            object: surfaceView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshPromptMarkersFromRuntime()
            }
        }
    }

    private func refreshPromptMarkersFromRuntime() {
        guard let surfaceView,
              let geometry = surfaceView.authoritativeScrollbarGeometry() else {
            promptMarkerOverlay.update(markers: [], geometry: nil)
            return
        }
        refreshPromptMarkers(using: geometry)
    }

    private func refreshPromptMarkers(using geometry: NotificationScrollRestoreGeometry) {
        let scrollbar = geometry.scrollbar
        let visibleRows = min(scrollbar.total, scrollbar.len)
        let lastTopRow = scrollbar.total - visibleRows

        promptScrollMarkers.removeAll {
            $0.rowSpaceRevision != geometry.rowSpaceRevision ||
            $0.topRow > lastTopRow
        }
        installPromptMarkerOverlayIfNeeded()
        promptMarkerOverlay.update(
            markers: promptScrollMarkers,
            geometry: geometry
        )
    }

    private func installPromptMarkerOverlayIfNeeded() {
        guard !promptScrollMarkers.isEmpty,
              let scroller = verticalScroller else { return }
        guard promptMarkerOverlay.superview !== scroller else { return }

        promptMarkerOverlay.removeFromSuperview()
        promptMarkerOverlay.scroller = scroller
        promptMarkerOverlay.frame = scroller.bounds
        promptMarkerOverlay.autoresizingMask = [.width, .height]
        scroller.addSubview(promptMarkerOverlay)
    }

    func activatePromptScrollMarker(
        _ marker: TerminalPromptScrollMarker
    ) -> Bool {
        guard let surfaceView,
              let geometry = surfaceView.authoritativeScrollbarGeometry(),
              let row = Int(exactly: marker.topRow) else { return false }

        guard geometry.rowSpaceRevision == marker.rowSpaceRevision else {
            refreshPromptMarkers(using: geometry)
            return false
        }

        let scrollbar = geometry.scrollbar
        let lastTopRow = scrollbar.total - min(scrollbar.total, scrollbar.len)
        guard marker.topRow <= lastTopRow else {
            refreshPromptMarkers(using: geometry)
            return false
        }

        let hostedView = superview as? GhosttySurfaceScrollView
        hostedView?.clearPendingNotificationScrollRestore()
        let previousIntent = hostedView?.prepareExplicitViewportRestore(
            isAtBottom: marker.topRow >= lastTopRow
        )

        guard let restoredGeometry = surfaceView.scrollToRow(
            row,
            ifRowSpaceRevisionMatches: marker.rowSpaceRevision
        ) else {
            if let hostedView, let previousIntent {
                hostedView.rollbackExplicitViewportRestore(to: previousIntent)
            }
            refreshPromptMarkers(using: geometry)
            return false
        }

        refreshPromptMarkers(using: restoredGeometry)
        return true
    }
}

@MainActor
extension GhosttySurfaceScrollView {
    private var promptMarkerScrollView: GhosttyScrollView? {
        subviews.compactMap { $0 as? GhosttyScrollView }.first
    }

    /// Records one prompt boundary using the terminal's authoritative row-space
    /// geometry. Prompt text remains in the existing workspace/session metadata;
    /// the scrollbar keeps only the row anchor needed for navigation.
    func recordPromptScrollMarker() {
        promptMarkerScrollView?.recordPromptScrollMarker()
    }

}
