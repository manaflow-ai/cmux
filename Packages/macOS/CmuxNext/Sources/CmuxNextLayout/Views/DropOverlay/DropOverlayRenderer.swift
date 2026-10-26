import AppKit
import CmuxNextDesign

/// Draws one `DropOverlayStyle`. Its view covers the overlay plane; each
/// animation frame passes the animated geometry. Colors are applied in
/// `applyTheme`, inside the view's theme scope.
@MainActor
protocol DropOverlayRenderer: AnyObject {
    var style: DropOverlayStyle { get }
    var view: NSView { get }
    /// The material its glass surfaces use (nil: the style draws no glass).
    var material: OverlayMaterial? { get }
    /// Pins one material on its glass surfaces (tests, `debug.drop_highlight`).
    func pinMaterial(_ material: OverlayMaterial?)
    func update(_ frame: DropOverlayFrame)
    func applyTheme()
    /// The renderer animates its own layers on the compositor
    /// (`frame.animated`): the highlight view runs no frame clock for it.
    var drivesOwnMotion: Bool { get }
    /// The overlay hides; a self-driven renderer fades itself.
    func hide(animated: Bool)
}

extension DropOverlayRenderer {
    var material: OverlayMaterial? { nil }
    func pinMaterial(_ material: OverlayMaterial?) {}
    var drivesOwnMotion: Bool { false }
    func hide(animated: Bool) {}
}

enum DropOverlayRenderers {
    static func make(_ style: DropOverlayStyle, material: OverlayMaterial?) -> any DropOverlayRenderer {
        switch style {
        case .outline: OutlineRenderer()
        case .glassFill, .morph: GlassFillRenderer(style: style, material: material)
        case .glassOutline: GlassOutlineRenderer(material: material)
        case .insetCard: InsetCardRenderer(material: material)
        case .splitPreview: SplitPreviewRenderer(material: material)
        case .tabGhost: TabGhostRenderer(material: material)
        case .insertionLine: InsertionLineRenderer()
        case .edgeGlow: EdgeGlowRenderer()
        case .dimOthers: DimOthersRenderer()
        case .hairline, .dashed, .corners: StrokeRenderer(style: style)
        }
    }

    /// A layer-backed container that never takes hits.
    static func container() -> NSView {
        let view = PassthroughView()
        view.wantsLayer = true
        view.autoresizingMask = [.width, .height]
        return view
    }

    /// A shape layer with no implicit animations.
    static func shape() -> CAShapeLayer {
        let layer = CAShapeLayer()
        layer.actions = ["path": NSNull(), "position": NSNull(), "bounds": NSNull(), "frame": NSNull(),
                         "fillColor": NSNull(), "strokeColor": NSNull(), "lineWidth": NSNull(), "opacity": NSNull()]
        return layer
    }

    /// Frames the shown `views` as one line in `bounds` (a glass surface's content) from
    /// ``ChipLayout``, `flexible` truncating to fit between the insets. The surface resizes every
    /// frame of the overlay's motion; this solves no constraints for it (Chromium's
    /// views::BoxLayout, ui/views/layout/box_layout.cc).
    static func placeRow(_ views: [NSView], flexible: NSView, spacing: CGFloat = 0, insets: ChipLayout.Insets,
                         in bounds: CGRect, centered: Bool, direction: NSUserInterfaceLayoutDirection) {
        let shown = views.filter { !$0.isHidden }
        let row = ChipLayout(items: shown.map { ChipLayout.Item(rowSize(of: $0), flexible: $0 === flexible) },
                             spacing: spacing, insets: insets)
        let frames = row.frames(placedIn: bounds, centered: centered, rightToLeft: direction == .rightToLeft)
        for (view, frame) in zip(shown, frames) { view.setAlignmentFrame(frame) }
    }

    /// A view's own alignment size in a row; none for a view with no intrinsic metric.
    static func rowSize(of view: NSView) -> CGSize {
        let size = view.intrinsicContentSize
        return CGSize(width: max(0, size.width), height: max(0, size.height))
    }
}
