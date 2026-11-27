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
}
