import AppKit
import SwiftUI

/// A geometry witness attached to the rendered tab or close-glyph slot.
struct CanvasTabHitRegionView: NSViewRepresentable {
    enum Kind { case tab, close }

    let tabId: UUID
    let kind: Kind
    let registry: CanvasTabGeometryRegistry

    final class RegionView: NSView {
        var tabId: UUID
        var kind: Kind
        weak var registry: CanvasTabGeometryRegistry?

        init(tabId: UUID, kind: Kind) {
            self.tabId = tabId
            self.kind = kind
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> RegionView {
        let view = RegionView(tabId: tabId, kind: kind)
        view.registry = registry
        registry.register(view)
        return view
    }

    func updateNSView(_ view: RegionView, context: Context) {
        view.tabId = tabId
        view.kind = kind
    }

    static func dismantleNSView(_ view: RegionView, coordinator: ()) {
        view.registry?.unregister(view)
    }
}
