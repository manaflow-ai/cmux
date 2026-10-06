import AppKit
import QuartzCore

// UIView, UIScrollView and the collection-view types that the shared catalyst
// sources use, as layer-only objects: a view is a CALayer owner, the layer's
// delegate, with UIKit's frame, subview, layout and drawing semantics. Rows
// are layers, not NSViews. The AppKit window hosts the root layer in one
// NSView (see Host.swift) and routes events into this tree.
//
// Semantics kept from UIKit because they change geometry or timing:
// - Layout runs in Core Animation's layout pass (`layoutSublayers(of:)` calls
//   `layoutSubviews`), exactly when UIKit runs it, including inside
//   `layoutIfNeeded()` and the transaction commit.
// - View layers have no implicit animations (the delegate returns NSNull).
// - A scroll view's bounds origin is its content offset; setting it lays the
//   view out again and calls `scrollViewDidScroll` synchronously.
// - Flexible-width and flexible-height autoresizing.
// - `draw(_:)` overrides get a y-down context at the layer's contentsScale.

class UIView: NSObject, CALayerDelegate {
    struct AutoresizingMask: OptionSet {
        let rawValue: Int
        static let flexibleWidth = AutoresizingMask(rawValue: 1 << 1)
        static let flexibleHeight = AutoresizingMask(rawValue: 1 << 4)
    }
    enum ContentMode { case scaleToFill, scaleAspectFit, scaleAspectFill, redraw, center }

    let layer: CALayer
    private(set) weak var superview: UIView?
    private(set) var subviews: [UIView] = []
    var isUserInteractionEnabled = true
    var autoresizingMask: AutoresizingMask = []
    var contentMode: ContentMode = .scaleToFill
    var isAccessibilityElement = false
    var accessibilityTraits: UIAccessibilityTraits = []
    var accessibilityLabel: String?

    init(frame: CGRect) {
        layer = CALayer()
        super.init()
        layer.delegate = self
        layer.contentsScale = DisplayScale.current
        layer.frame = frame
        if overridesDraw { layer.setNeedsDisplay() }
    }
    override convenience init() { self.init(frame: .zero) }

    // MARK: Geometry

    var frame: CGRect {
        get { layer.frame }
        set {
            let old = layer.bounds.size
            layer.frame = newValue
            if layer.bounds.size != old { sizeChanged(from: old) }
        }
    }
    var bounds: CGRect {
        get { layer.bounds }
        set {
            let old = layer.bounds.size
            layer.bounds = newValue
            if layer.bounds.size != old { sizeChanged(from: old) }
        }
    }
    var center: CGPoint {
        get { layer.position }
        set { layer.position = newValue }
    }

    private func sizeChanged(from old: CGSize) {
        setNeedsLayout()
        let dw = layer.bounds.width - old.width, dh = layer.bounds.height - old.height
        for v in subviews where !v.autoresizingMask.isEmpty {
            var f = v.frame
            if v.autoresizingMask.contains(.flexibleWidth) { f.size.width += dw }
            if v.autoresizingMask.contains(.flexibleHeight) { f.size.height += dh }
            v.frame = f
        }
        if contentMode == .redraw { layer.setNeedsDisplay() }
    }

    var backgroundColor: UIColor? { didSet { layer.backgroundColor = backgroundColor?.cgColor } }
    var alpha: CGFloat {
        get { CGFloat(layer.opacity) }
        set { layer.opacity = Float(newValue) }
    }
    var isHidden: Bool {
        get { layer.isHidden }
        set { layer.isHidden = newValue }
    }
    var clipsToBounds: Bool {
        get { layer.masksToBounds }
        set { layer.masksToBounds = newValue }
    }
    var isOpaque: Bool {
        get { layer.isOpaque }
        set { layer.isOpaque = newValue }
    }

    // MARK: Hierarchy

    func addSubview(_ v: UIView) {
        if v.superview === self, let i = subviews.firstIndex(of: v) { subviews.remove(at: i) } else { v.removeFromSuperview() }
        subviews.append(v)
        v.superview = self
        layer.addSublayer(v.layer)
    }
    func insertSubview(_ v: UIView, belowSubview sibling: UIView) {
        v.removeFromSuperview()
        let i = subviews.firstIndex(of: sibling) ?? 0
        subviews.insert(v, at: i)
        v.superview = self
        layer.insertSublayer(v.layer, below: sibling.layer)
    }
    func insertSubview(_ v: UIView, aboveSubview sibling: UIView) {
        v.removeFromSuperview()
        let i = (subviews.firstIndex(of: sibling) ?? subviews.count - 1) + 1
        subviews.insert(v, at: i)
        v.superview = self
        layer.insertSublayer(v.layer, above: sibling.layer)
    }
    func removeFromSuperview() {
        guard let s = superview else { return }
        if let i = s.subviews.firstIndex(of: self) { s.subviews.remove(at: i) }
        superview = nil
        layer.removeFromSuperlayer()
    }
    func bringSubviewToFront(_ v: UIView) {
        guard v.superview === self else { return }
        addSubview(v)
    }

    // MARK: Layout

    func layoutSubviews() {}
    /// UIKit's own layout flag. `layoutIfNeeded()` lays out this view and its
    /// subviews, top down, and never its ancestors (Core Animation's
    /// `-[CALayer layoutIfNeeded]` starts at the topmost ancestor that needs
    /// layout, which ran the window view's layout too early at launch). Core
    /// Animation's own pass (transaction commit) calls `layoutSublayers(of:)`,
    /// which lays out only a view that still needs it.
    private var needsLayoutFlag = true
    /// Called by the AppKit host when the tree is put in a window and when the
    /// window's backing scale changes (UIKit: window or screen changes).
    func didMoveToWindow() {}
    func moveToWindowRecursively() { didMoveToWindow(); subviews.forEach { $0.moveToWindowRecursively() } }
    func setNeedsLayout() { needsLayoutFlag = true; layer.setNeedsLayout() }
    func layoutIfNeeded() {
        if needsLayoutFlag { needsLayoutFlag = false; layoutSubviews() }
        for v in subviews { v.layoutIfNeeded() }
    }
    func layoutSublayers(of layer: CALayer) {
        guard layer === self.layer, needsLayoutFlag else { return }
        needsLayoutFlag = false
        layoutSubviews()
    }

    // MARK: Drawing

    @objc dynamic func draw(_ rect: CGRect) {}
    func setNeedsDisplay() { layer.setNeedsDisplay() }

    var overridesDraw: Bool {
        let sel = #selector(UIView.draw(_:))
        return class_getMethodImplementation(type(of: self), sel) != class_getMethodImplementation(UIView.self, sel)
    }

    func draw(_ layer: CALayer, in ctx: CGContext) {
        guard layer === self.layer else { return }
        // Core Animation flips the context for a layer whose geometry is
        // flipped (the whole tree is y-down); make sure it is y-down here.
        if !layer.contentsAreFlipped() {
            ctx.translateBy(x: 0, y: layer.bounds.height)
            ctx.scaleBy(x: 1, y: -1)
        }
        ContextScope.run(ctx) { draw(bounds) }
    }

    func action(for layer: CALayer, forKey event: String) -> CAAction? { NSNull() }

    // MARK: Conversion

    func convert(_ r: CGRect, to view: UIView?) -> CGRect { layer.convert(r, to: (view ?? rootView).layer) }
    func convert(_ p: CGPoint, to view: UIView?) -> CGPoint { layer.convert(p, to: (view ?? rootView).layer) }
    func convert(_ r: CGRect, from view: UIView?) -> CGRect { layer.convert(r, from: (view ?? rootView).layer) }
    func convert(_ p: CGPoint, from view: UIView?) -> CGPoint { layer.convert(p, from: (view ?? rootView).layer) }
    var rootView: UIView { superview?.rootView ?? self }

    // MARK: Animation

    static func performWithoutAnimation(_ body: () -> Void) { body() }
}

final class UIImageView: UIView {
    var image: UIImage? {
        didSet {
            layer.contents = image?.cgImage
            if let s = image?.scale { layer.contentsScale = s }
        }
    }
}

/// The header's live material: a real NSVisualEffectView that the window
/// places at this view's frame, above the transcript (Host.swift). It has no
/// pixels in the layer tree, so captures use the fitted blur instead.
final class UIVisualEffectView: UIView {
    let effectView = NSVisualEffectView()
    static var all = NSHashTable<UIVisualEffectView>.weakObjects()
    init(effect: UIBlurEffect) {
        super.init(frame: .zero)
        effectView.material = effect.material
        effectView.blendingMode = .withinWindow
        effectView.state = .active
        UIVisualEffectView.all.add(self)
    }
    required init?(coder: NSCoder) { fatalError() }
}

struct UIBlurEffect {
    enum Style { case systemThickMaterialDark, systemMaterialDark, systemThinMaterialDark }
    var style: Style
    init(style: Style) { self.style = style }
    var material: NSVisualEffectView.Material {
        switch style {
        case .systemThickMaterialDark: return .headerView
        case .systemMaterialDark: return .titlebar
        case .systemThinMaterialDark: return .hudWindow
        }
    }
}

// MARK: Gestures (state only; AppKit events drive them)

class UIGestureRecognizer {
    enum State { case possible, began, changed, ended, cancelled, failed }
    var state: State = .possible
}
final class UIPanGestureRecognizer: UIGestureRecognizer {}

// MARK: Scroll view

protocol UIScrollViewDelegate: AnyObject {
    func scrollViewDidScroll(_ scrollView: UIScrollView)
}
extension UIScrollViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {}
}

class UIScrollView: UIView {
    enum ContentInsetAdjustmentBehavior { case automatic, scrollableAxes, never, always }

    weak var delegate: UIScrollViewDelegate?
    var contentSize: CGSize = .zero
    /// UIKit clamps the offset into the new range when the insets change
    /// at rest (`_adjustContentOffsetIfNecessary`; not while tracking or
    /// decelerating). The window view sets the insets before the offset, so
    /// at launch, with no content size yet, the offset goes to the top.
    var contentInset: UIEdgeInsets = .zero {
        didSet {
            guard contentInset != oldValue, !isTracking, !isDecelerating else { return }
            let y = min(max(contentOffset.y, minOffsetY), maxOffsetY)
            if y != contentOffset.y { contentOffset = CGPoint(x: contentOffset.x, y: y) }
        }
    }
    var alwaysBounceVertical = false
    var showsVerticalScrollIndicator = true
    var contentInsetAdjustmentBehavior: ContentInsetAdjustmentBehavior = .automatic
    let panGestureRecognizer = UIPanGestureRecognizer()
    /// Scroll physics (trackpad phases, wheel, momentum, rubber band): the
    /// AppKit scroll host, matched to Catalyst's UIScrollView.
    lazy var physics = ScrollPhysics(self)

    var isTracking: Bool { physics.isTracking }
    var isDragging: Bool { physics.isDragging }
    var isDecelerating: Bool { physics.isDecelerating }

    /// UIKit rounds the offset to the device pixel grid (scripted and
    /// physics offsets alike).
    var contentOffset: CGPoint {
        get { layer.bounds.origin }
        set {
            let s = DisplayScale.current
            let newValue = CGPoint(x: (newValue.x * s).rounded() / s, y: (newValue.y * s).rounded() / s)
            guard newValue != layer.bounds.origin else { return }
            layer.bounds.origin = newValue
            setNeedsLayout()
            delegate?.scrollViewDidScroll(self)
        }
    }
    func setContentOffset(_ p: CGPoint, animated: Bool) { contentOffset = p }

    /// The offset range UIKit allows at rest (insets included).
    var minOffsetY: CGFloat { -contentInset.top }
    var maxOffsetY: CGFloat { max(-contentInset.top, contentSize.height + contentInset.bottom - bounds.height) }
}

// MARK: Collection view (types only: the AppKit port uses the row recycler)

protocol UICollectionViewDataSource: AnyObject {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell
}
protocol UICollectionViewDelegate: UIScrollViewDelegate {}
protocol UICollectionViewDataSourcePrefetching: AnyObject {
    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath])
}

/// Not used at run time: `--transcript collection` needs UIKit's
/// UICollectionView, which AppKit does not have. The recycler is the default
/// in both apps.
class UICollectionView: UIScrollView {
    weak var dataSource: UICollectionViewDataSource?
    weak var prefetchDataSource: UICollectionViewDataSourcePrefetching?
    var isPrefetchingEnabled = false
    let collectionViewLayout: UICollectionViewLayout
    init(frame: CGRect, collectionViewLayout: UICollectionViewLayout) {
        self.collectionViewLayout = collectionViewLayout
        super.init(frame: frame)
        fatalError("appkit-port: --transcript collection is not available; the row recycler is the transcript")
    }
    required init?(coder: NSCoder) { fatalError() }
    func register(_ cellClass: AnyClass?, forCellWithReuseIdentifier id: String) {}
    func dequeueReusableCell(withReuseIdentifier id: String, for indexPath: IndexPath) -> UICollectionViewCell { UICollectionViewCell(frame: .zero) }
    var visibleCells: [UICollectionViewCell] { [] }
    func indexPath(for cell: UICollectionViewCell) -> IndexPath? { nil }
    func reloadData() {}
    func performBatchUpdates(_ updates: (() -> Void)?, completion: ((Bool) -> Void)?) { updates?(); completion?(true) }
    func insertItems(at indexPaths: [IndexPath]) {}
    func deleteItems(at indexPaths: [IndexPath]) {}
}

class UICollectionViewCell: UIView {
    let contentView = UIView()
    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.frame = CGRect(origin: .zero, size: frame.size)
        contentView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(contentView)
    }
    required init?(coder: NSCoder) { fatalError() }
    func prepareForReuse() {}
    func preferredLayoutAttributesFitting(_ attrs: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes { attrs }
}

class UICollectionViewLayoutAttributes: NSObject {
    let indexPath: IndexPath
    var frame: CGRect = .zero
    var zIndex = 0
    init(forCellWith indexPath: IndexPath) { self.indexPath = indexPath }
}

class UICollectionViewLayoutInvalidationContext: NSObject {
    fileprivate(set) var invalidateEverything = false
    var invalidateDataSourceCounts = false
    var contentOffsetAdjustment: CGPoint = .zero
    var contentSizeAdjustment: CGSize = .zero
    override init() { super.init() }
}

class UICollectionViewLayout: NSObject {
    override init() { super.init() }
    var collectionViewContentSize: CGSize { .zero }
    /// UIKit's `invalidateLayout()` invalidates everything.
    func invalidateLayout() {
        let c = UICollectionViewLayoutInvalidationContext()
        c.invalidateEverything = true
        invalidateLayout(with: c)
    }
    func invalidateLayout(with context: UICollectionViewLayoutInvalidationContext) {}
    func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? { nil }
    func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? { nil }
    func targetContentOffset(forProposedContentOffset p: CGPoint) -> CGPoint { p }
    func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool { false }
}
