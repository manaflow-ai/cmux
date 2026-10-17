import AppKit

/// A color property of a layer that a theme repaint blends (I5, cx-8w027.3).
nonisolated enum LayerColor: String, CaseIterable {
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

/// The theme repaint (I5, cx-8w027.3): every view a change recolors runs its theme hook once
/// (`viewDidChangeEffectiveAppearance` and a display), with no layout pass unless a metric
/// changed, and every layer color the hooks change blends on the render server from the color
/// on screen (``ColorTransition``). No window capture, no image copy, no forced commit and no
/// per-frame main-thread work; colors drawn in `draw(_:)` (text, terminal surfaces) switch at
/// once.
///
/// Changes collect in a ``batch(_:)``: each scope asks for its region once (``request(_:roots:scope:animated:layout:)``)
/// and defers its window and root appearances (``beforeHooks(_:)``). The batch then records the
/// colors on screen, applies the appearances, runs each view's hook once (a view in two regions
/// runs once) and blends what changed. Appearances come after the record, so a light/dark flip
/// blends too.
@MainActor
enum ThemeRepaint {
    private struct Request {
        var roots: () -> [NSView]
        var scope: ThemeScope?
        var animated: Bool
        var layout: Bool
    }

    private static var depth = 0
    private static var order: [ObjectIdentifier] = []
    private static var requests: [ObjectIdentifier: Request] = [:]
    private static var appearanceWork: [() -> Void] = []

    /// Runs `body` as one repaint: every request and appearance it makes applies at its end.
    static func batch<T>(_ body: () -> T) -> T {
        depth += 1
        defer {
            depth -= 1
            if depth == 0 { commit() }
        }
        return body()
    }

    /// Repaints the views under `roots()` that draw in `scope` (``views(under:scope:)``) at the
    /// end of the batch. `owner` names the region: a second request for it merges (animated or
    /// layout if any asked). `animated` blends what changes in windows on screen; `layout` also
    /// lays the views out again (a border width or font changed, not only colors).
    static func request(_ owner: AnyObject, roots: @escaping () -> [NSView], scope: ThemeScope?, animated: Bool, layout: Bool = false) {
        let key = ObjectIdentifier(owner)
        if var existing = requests[key] {
            existing.animated = existing.animated || animated
            existing.layout = existing.layout || layout
            requests[key] = existing
        } else {
            order.append(key)
            requests[key] = Request(roots: roots, scope: scope, animated: animated, layout: layout)
        }
        if depth == 0 { commit() }
    }

    /// Runs `work` (an appearance change) after the batch recorded the colors on screen and
    /// before the hooks; at once outside a batch.
    static func beforeHooks(_ work: @escaping () -> Void) {
        if depth == 0 { work() } else { appearanceWork.append(work) }
    }

    private static func commit() {
        // Requests made while this one runs (a hook that changes a scope) form the next round.
        var rounds = 0
        while !order.isEmpty || !appearanceWork.isEmpty, rounds < 8 {
            rounds += 1
            let pending = order.compactMap { requests[$0] }
            let work = appearanceWork
            order = []
            requests = [:]
            appearanceWork = []
            depth = 1
            apply(pending, work: work)
            depth = 0
        }
    }

    private static func apply(_ pending: [Request], work: [() -> Void]) {
        let transition = ColorTransition.current
        var seen = Set<ObjectIdentifier>()
        var passes: [(views: [NSView], layout: Bool)] = []
        var blendRoots: [NSView] = []
        var shown: [(layer: CALayer, colors: [(LayerColor, CGColor?)])] = []
        for request in pending {
            let roots = request.roots()
            let views = views(under: roots, scope: request.scope, seen: &seen)
            passes.append((views, request.layout))
            guard request.animated, !transition.isInstant else { continue }
            let onScreen = views.filter { $0.window.map(isOnScreen) == true }
            guard !onScreen.isEmpty else { continue }
            for view in onScreen { if let layer = view.layer { collect(layer, into: &shown) } }
            blendRoots += roots.filter { $0.window.map(isOnScreen) == true }
        }
        for change in work { change() }
        for pass in passes {
            for view in pass.views {
                view.viewDidChangeEffectiveAppearance()
                view.needsDisplay = true
                if pass.layout { view.needsLayout = true }
            }
        }
        guard !shown.isEmpty else { return }
        // The views display now (the work the next display cycle does), so colors set in
        // `layout()` and `updateLayer()` blend too.
        for root in blendRoots {
            root.layoutSubtreeIfNeeded()
            root.displayIfNeeded()
        }
        for entry in shown {
            for (property, before) in entry.colors {
                let now = property.value(in: entry.layer)
                if !same(before, now) { transition.blend(entry.layer, property, from: before, to: now) }
            }
        }
    }

    /// The views under `roots` that draw in `scope`: each root and its subtree, without the
    /// subtrees of views that root another scope (those repaint when their own scope's colors
    /// change). A nil `scope` keeps every subtree (a Ghostty config change recolors every scope).
    /// Views in `seen` (another region of the batch) are left out.
    private static func views(under roots: [NSView], scope: ThemeScope?, seen: inout Set<ObjectIdentifier>) -> [NSView] {
        var result: [NSView] = []
        func visit(_ view: NSView) {
            guard seen.insert(ObjectIdentifier(view)).inserted else { return }
            result.append(view)
            for subview in view.subviews where !rootsOther(subview, than: scope) { visit(subview) }
        }
        for root in roots where !rootsOther(root, than: scope) { visit(root) }
        return result
    }

    private static func rootsOther(_ view: NSView, than scope: ThemeScope?) -> Bool {
        guard let scope, let own = ThemeScopeRegistry.scope(of: view) else { return false }
        return own !== scope
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
