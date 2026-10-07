import AppKit
import CmuxNextDesign

/// The tab drop outline over the sidebar: the shared `DropOutlineRing`
/// around the slot, row or "+" button a dragged tab would land on, or in
/// the danger color around a row that refuses it (tab-dnd, coordinator
/// decision 2026-10-04: one border preview at every point, the sidebar
/// too). It covers the sidebar, takes no mouse, and is added on first use.
final class SidebarDropOutlineView: NSView {
    let ring = DropOutlineRing()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        autoresizingMask = [.width, .height]
        layer?.addSublayer(ring.layer)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        performWithTheme { ring.applyTheme() }
    }
}

extension SidebarView {
    /// Outlines `windowRect` (window coordinates) over the sidebar.
    func showDropOutline(_ windowRect: CGRect, refused: Bool) {
        let overlay = dropOutlineView ?? {
            let view = SidebarDropOutlineView(frame: bounds)
            addSubview(view, positioned: .above, relativeTo: nil)
            return view
        }()
        if overlay !== subviews.last { addSubview(overlay, positioned: .above, relativeTo: nil) }
        let rect = overlay.convert(windowRect, from: nil)
        overlay.performWithTheme {
            overlay.ring.show(rect, cornerRadius: min(Metrics.space2, rect.height / 2), refused: refused, animated: Motion.animatesMovement)
        }
    }

    func hideDropOutline() {
        dropOutlineView?.ring.hide(animated: Motion.animatesFades)
    }

    /// The outline overlay, once a drag has used it (tests read its ring).
    var dropOutlineView: SidebarDropOutlineView? {
        subviews.lazy.compactMap { $0 as? SidebarDropOutlineView }.first
    }
}
