import AppKit

/// A color property of a layer that a theme repaint blends (I5, cx-8w027.3).
enum LayerColor: String, CaseIterable {
    case backgroundColor, borderColor, shadowColor
    /// `CAShapeLayer` only.
    case fillColor, strokeColor
    /// `CATextLayer` only.
    case foregroundColor

    /// The layer animation key of a blend of this property.
    var animationKey: String { "cmux.colorTransition.\(rawValue)" }

    /// The properties `layer` has.
    static func properties(of layer: CALayer) -> [LayerColor] {
        if layer is CAShapeLayer { return [.backgroundColor, .borderColor, .shadowColor, .fillColor, .strokeColor] }
        if layer is CATextLayer { return [.backgroundColor, .borderColor, .shadowColor, .foregroundColor] }
        return [.backgroundColor, .borderColor, .shadowColor]
    }

    /// The model value.
    @MainActor
    func value(in layer: CALayer) -> CGColor? {
        switch self {
        case .backgroundColor: return layer.backgroundColor
        case .borderColor: return layer.borderColor
        case .shadowColor: return layer.shadowColor
        case .fillColor: return (layer as? CAShapeLayer)?.fillColor
        case .strokeColor: return (layer as? CAShapeLayer)?.strokeColor
        case .foregroundColor: return (layer as? CATextLayer)?.foregroundColor
        }
    }

    /// The value on screen: the presentation value while the layer runs any animation (a blend
    /// in flight, a hover fade), else the model value.
    @MainActor
    func shown(in layer: CALayer) -> CGColor? {
        guard layer.animationKeys()?.isEmpty == false, let presented = layer.presentation() else { return value(in: layer) }
        return value(in: presented)
    }
}

/// One theme repaint over the views of one region (I5, cx-8w027.3): every view's theme hook runs
/// once (`viewDidChangeEffectiveAppearance` and a display), with no layout pass
/// unless a metric changed, and every layer color the hooks change blends on the render server
/// from the color on screen (``ColorTransition``). No window capture, no image copy, no forced
/// commit and no per-frame main-thread work; colors drawn in `draw(_:)` (text, terminal
/// surfaces) switch at once.
@MainActor
enum ThemeRepaint {
    /// The views under `roots` that draw in `scope`: each root and its subtree, without the
    /// subtrees of views that root another scope (those repaint when their own scope's colors
    /// change). A nil `scope` keeps every subtree (a Ghostty config change recolors every scope).
    private static func views(under roots: [NSView], scope: ThemeScope?) -> [NSView] {
        var result: [NSView] = []
        var seen = Set<ObjectIdentifier>()
        func visit(_ view: NSView) {
            guard seen.insert(ObjectIdentifier(view)).inserted else { return }
            result.append(view)
            for subview in view.subviews {
                if let scope, let own = ThemeScopeRegistry.scope(of: subview), own !== scope { continue }
                visit(subview)
            }
        }
        for root in roots { visit(root) }
        return result
    }

    /// Runs the theme hook of every view under `roots` that draws in `scope` (``views(under:scope:)``)
    /// once and marks it for display. `transition` (nil or instant: none) blends what changed in
    /// windows on screen: the views display at once (the same work the next display cycle does),
    /// so colors set in `updateLayer` blend too. `layout` also lays the views out again (a border
    /// width or font changed, not only colors).
    static func run(under roots: [NSView], scope: ThemeScope?, transition: ColorTransition?, layout: Bool = false) {
        let views = views(under: roots, scope: scope)
        let blends = transition.flatMap { $0.isInstant ? nil : $0 }
        var shown: [(layer: CALayer, colors: [(LayerColor, CGColor?)])] = []
        if blends != nil {
            for view in views where view.window.map(isOnScreen) == true {
                if let layer = view.layer { collect(layer, into: &shown) }
            }
        }
        for view in views {
            view.viewDidChangeEffectiveAppearance()
            view.needsDisplay = true
            if layout { view.needsLayout = true }
        }
        guard let blends, !shown.isEmpty else { return }
        for root in roots where root.window.map(isOnScreen) == true { root.displayIfNeeded() }
        for entry in shown {
            for (property, before) in entry.colors {
                let now = property.value(in: entry.layer)
                if !same(before, now) { blends.blend(entry.layer, property, from: before, to: now) }
            }
        }
    }

    /// `layer`'s colors as shown now, and those of the sublayers it owns (not the layers of
    /// subviews: those views are in the pass themselves or draw in another scope).
    private static func collect(_ layer: CALayer, into shown: inout [(layer: CALayer, colors: [(LayerColor, CGColor?)])]) {
        if !ownBlends.contains(layer) {
            shown.append((layer, LayerColor.properties(of: layer).map { ($0, $0.shown(in: layer)) }))
        }
        for sublayer in layer.sublayers ?? [] where !(sublayer.delegate is NSView) {
            collect(sublayer, into: &shown)
        }
    }

    /// Layers whose owner runs its own color transition (``ownsBlend(_:)``).
    private static let ownBlends = NSHashTable<CALayer>.weakObjects()

    /// Leaves `layer`'s colors out of every repaint's blend: its owner animates them itself.
    static func ownsBlend(_ layer: CALayer?) {
        if let layer { ownBlends.add(layer) }
    }

    private static func isOnScreen(_ window: NSWindow) -> Bool {
        window.isVisible && window.occlusionState.contains(.visible)
    }

    private static func same(_ a: CGColor?, _ b: CGColor?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (a?, b?): return a == b
        default: return false
        }
    }
}
