import AppKit
import CmuxNextWakeups
import CmuxNextDesignTokens

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
/// per-frame main-thread work. Terminal surfaces blend their own colors on the GPU with the same
/// curve (`ghostty_surface_set_color_transition`); colors drawn in `draw(_:)` switch at once.
///
/// Changes collect in a ``batch(_:)``: each scope asks for its region once (``request(_:roots:scope:animated:layout:)``)
/// and defers its window and root appearances (``beforeHooks(_:)``). The batch then records the
/// colors on screen, applies the appearances, runs each view's hook once (a view in two regions
/// runs once) and blends what changed. Appearances come after the record, so a light/dark flip
/// blends too.
@MainActor
enum ThemeRepaint {
    private struct Request {
        /// Kept until the batch ends, so its identifier names only it.
        var owner: AnyObject
        var roots: () -> [NSView]
        var scope: ThemeScope?
        var animated: Bool
        var layout: Bool
        /// Hidden subtrees wait until shown (a theme change); false paints them now (a subtree's
        /// first paint in a scope).
        var lazy: Bool
    }

    private static var depth = 0
    private static var order: [ObjectIdentifier] = []
    private static var requests: [ObjectIdentifier: Request] = [:]
    private static var appearanceWork: [() -> Void] = []
    private static var responderWork: [() -> Void] = []

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
    static func request(_ owner: AnyObject, roots: @escaping () -> [NSView], scope: ThemeScope?, animated: Bool,
                        layout: Bool = false, lazy: Bool = true) {
        let key = ObjectIdentifier(owner)
        if var existing = requests[key] {
            existing.animated = existing.animated || animated
            existing.layout = existing.layout || layout
            existing.lazy = existing.lazy && lazy
            requests[key] = existing
        } else {
            order.append(key)
            requests[key] = Request(owner: owner, roots: roots, scope: scope, animated: animated, layout: layout, lazy: lazy)
        }
        if depth == 0 { commit() }
    }

    /// Runs `work` (an appearance change) after the batch recorded the colors on screen and
    /// before the hooks; at once outside a batch.
    static func beforeHooks(_ work: @escaping () -> Void) {
        if depth == 0 { work() } else { appearanceWork.append(work) }
    }

    /// Runs `work` (a `ThemeResponsive` call) after the batch's hooks, before its blends: its
    /// colors blend too, and it sees the new appearances. At once outside a batch.
    static func afterHooks(_ work: @escaping () -> Void) {
        if depth == 0 { work() } else { responderWork.append(work) }
    }

    private static var hasWork: Bool { !order.isEmpty || !appearanceWork.isEmpty || !responderWork.isEmpty }

    private static func commit() {
        // Requests made while this one runs (a hook that changes a scope) form the next round.
        var rounds = 0
        while hasWork {
            rounds += 1
            // A hook that keeps asking for repaints: the last round applies without a blend.
            let last = rounds >= 8
            // Animated regions first: a view in two regions is recorded for its blend.
            var pending = order.compactMap { requests[$0] }.sorted { $0.animated && !$1.animated }
            if last { pending = pending.map { var request = $0; request.animated = false; return request } }
            let work = appearanceWork, responders = responderWork
            order = []
            requests = [:]
            appearanceWork = []
            responderWork = []
            depth = 1
            apply(pending, work: work, responders: responders)
            depth = 0
            if last {
                order = []
                requests = [:]
                appearanceWork = []
                responderWork = []
                break
            }
        }
    }

    private static func apply(_ pending: [Request], work: [() -> Void], responders: [() -> Void]) {
        let transition = ColorTransition.current
        var seen = Set<ObjectIdentifier>()
        var passes: [(views: [NSView], layout: Bool)] = []
        var blendRoots: [NSView] = []
        // memory: fixed a local of one repaint, kept by no one: one entry per on-screen layer of the batch's views, dropped when `apply` returns
        var shown: [(layer: CALayer, colors: [(LayerColor, CGColor?)])] = []
        for request in pending {
            let roots = request.roots()
            let views = views(under: roots, scope: request.scope, layout: request.layout, lazy: request.lazy, seen: &seen)
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
                // invalidate: the view's theme scope changed (a repaint request); its colors resolve again.
                view.needsDisplay = true
                // invalidate: the request asked for layout (a view whose layout() sets colors).
                if pass.layout { view.needsLayout = true }
            }
        }
        for responder in responders { responder() }
        guard !shown.isEmpty else { return }
        // The views lay out and display now (the work the next display cycle does), so colors
        // set in `updateLayer()`, and in `layout()` by a view whose hook asks for layout, blend too.
        for root in blendRoots {
            // sync-layout: the blend below reads each layer's new color, set in layout() and updateLayer().
            root.layoutSubtreeIfNeeded()
            root.displayIfNeeded() // sync-layout: the blend below reads the colors updateLayer() sets.
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
    /// Views in `seen` (another region of the batch) are left out. A hidden subtree (a parked
    /// workspace or tab, a hidden control) is left out too and repaints when it is shown
    /// (``markStale(_:scope:layout:)``).
    private static func views(under roots: [NSView], scope: ThemeScope?, layout: Bool, lazy: Bool,
                              seen: inout Set<ObjectIdentifier>) -> [NSView] {
        var result: [NSView] = []
        let anyStale = stale.count > 0
        for root in roots where !rootsOther(root, than: scope) {
            visit(root, scope: scope, layout: layout, lazy: lazy, anyStale: anyStale, seen: &seen, into: &result)
        }
        return result
    }

    /// One view of ``views(under:scope:layout:lazy:seen:)`` and its subtree, in order. A static
    /// function with inout state, not a local function that captures it (Swift 6.3.3's
    /// SendNonSendable pass crashed now and then on such captures in Release).
    private static func visit(_ view: NSView, scope: ThemeScope?, layout: Bool, lazy: Bool, anyStale: Bool,
                              seen: inout Set<ObjectIdentifier>, into result: inout [NSView]) {
        guard seen.insert(ObjectIdentifier(view)).inserted else { return }
        if lazy, view.isHidden { return markStale(view, scope: scope, layout: layout) }
        // Painted now: a mark from an earlier pass is done.
        if anyStale, let region = stale.object(forKey: view) { forget(view, region) }
        result.append(view)
        for subview in view.subviews where !rootsOther(subview, than: scope) {
            visit(subview, scope: scope, layout: layout, lazy: lazy, anyStale: anyStale, seen: &seen, into: &result)
        }
    }

    // MARK: Hidden subtrees

    /// A hidden subtree a repaint left out: the scope whose pass skipped it and the revision of
    /// the first pass it missed (``ThemeScope/paintRevision``), and the observation that
    /// repaints it when shown.
    private final class StaleRegion {
        weak var scope: ThemeScope?
        var scoped: Bool
        var revision: Int
        /// A skipped pass also laid out (a border width or font changed).
        var layout = false
        var observation: NSKeyValueObservation?

        init(scope: ThemeScope?) {
            self.scope = scope
            scoped = scope != nil
            revision = scope?.paintRevision ?? 0
        }

        /// Another pass skipped the same subtree: one repaint on show covers both, in the wider
        /// region when the passes came from different scopes (the view moved, or a config change).
        func merge(scope other: ThemeScope?, layout: Bool) {
            self.layout = self.layout || layout
            guard scoped, other !== scope else { return }
            scope = nil
            scoped = false
        }
    }

    private static let stale = NSMapTable<NSView, StaleRegion>(keyOptions: .weakMemory, valueOptions: .strongMemory)

    /// Leaves the hidden `view` (and its subtree) for later: when it is shown, its subtree runs its
    /// hooks once, if its scope repainted since (I5: a hidden or parked view costs nothing per
    /// theme change). One mark per view, whatever the number of changes while hidden.
    private static func markStale(_ view: NSView, scope: ThemeScope?, layout: Bool) {
        if let marked = stale.object(forKey: view) { return marked.merge(scope: scope, layout: layout) }
        let region = StaleRegion(scope: scope)
        region.layout = layout
        // raw-observer-allow: one KVO of this skipped view's own isHidden, dropped at its show; no notice or node says an arbitrary view shows
        region.observation = view.observe(\.isHidden, options: [.new]) { view, _ in
            // main-hop-allow: AppKit sets isHidden on main, so the repaint runs inline in the show's turn; only an off-main write hops
            MainDelivery().run { didShow(view) }
        }
        stale.setObject(region, forKey: view)
    }

    private static func forget(_ view: NSView, _ region: StaleRegion) {
        region.observation?.invalidate()
        stale.removeObject(forKey: view)
    }

    /// `view` was shown (or hidden again): a marked subtree missed the passes from
    /// `region.revision` on and repaints once now, without a blend (content that appears does not
    /// fade). A pass that reached the view meanwhile already dropped the mark. A view must be
    /// shown through its own `isHidden`; one moved out of a hidden ancestor repaints with the
    /// next pass that reaches it.
    private static func didShow(_ view: NSView) {
        guard !view.isHidden, let region = stale.object(forKey: view) else { return }
        forget(view, region)
        // The scope is gone (its owner closed) and the view did not move: nothing draws in it.
        if region.scoped, region.scope == nil { return }
        batch { request(view, roots: { () -> [NSView] in [view] }, scope: region.scope, animated: false, layout: region.layout) }
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
