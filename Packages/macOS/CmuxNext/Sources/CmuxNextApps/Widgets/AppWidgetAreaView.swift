public import AppKit
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextWakeups

/// The sidebar's widget area in AppKit: the person's tiles on the New Tab tile unit, sized to the
/// sidebar (small two per row, medium the full width), each a ``AppWidgetTileView`` drawing its
/// mount's scene. It tells the area which tiles show (`apps.widgets.visible`): a tile is hidden
/// while the sidebar is collapsed, the window covered or minimized, or its section folded (the band
/// then takes the view out of the window). Edit mode, as
/// Apple's: minus badges, a drag arranges, the tile menu resizes, Add Widget opens the gallery.
public final class AppWidgetAreaView: NSView {
    public let area: AppWidgetArea
    /// Runs when ``preferredHeight(width:)`` may have changed.
    public var onContentSizeChange: (() -> Void)?
    var tileViews: [String: AppWidgetTileView] = [:]
    let grid = AppWidgetGrid(gap: Metrics.space2, inset: Metrics.space2)
    private let editBar = NSStackView()
    private lazy var addButton = ThemedBezelButton(title: AppWidgetStrings.add, target: self, action: #selector(addWidget))
    private lazy var doneButton = ThemedBezelButton(title: AppWidgetStrings.done, target: self, action: #selector(endEditing))
    lazy var gallery = AppWidgetGallery(area: area)
    /// The order shown while a tile is dragged (the lifted tile follows the pointer).
    var drag: AppWidgetDrag?
    /// Opens the gallery once the view is in a window (asked for before the area showed).
    private var galleryPending = false
    /// The gallery was made (``gallery`` is lazy).
    private var galleryOpened = false
    /// The window whose occlusion the area follows (through the app's one sight observer).
    private weak var sightWindow: NSWindow?

    public init(area: AppWidgetArea) {
        self.area = area
        super.init(frame: .zero)
        editBar.orientation = .horizontal
        editBar.spacing = Metrics.space2
        editBar.addArrangedSubview(addButton)
        editBar.addArrangedSubview(NSView())
        editBar.addArrangedSubview(doneButton)
        editBar.isHidden = true
        addSubview(editBar)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(AppWidgetStrings.sectionTitle)
        setAccessibilityIdentifier("cmux.widgets.sidebar")
        sync(animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public nonisolated override var isFlipped: Bool { true }

    // MARK: Tiles

    /// Makes a view per mounted tile, drops the views of tiles that left, and lays out again
    /// (animated through the sidebar motion gate when the tiles moved).
    public func sync(animated: Bool = true) {
        var live = Set<String>()
        for tile in area.tiles {
            guard let mount = area.mounted[tile.instance]?.mount else { continue }
            live.insert(tile.instance)
            if let view = tileViews[tile.instance], view.mount === mount { continue }
            tileViews[tile.instance]?.removeFromSuperview()
            let view = AppWidgetTileView(instance: tile.instance, mount: mount)
            view.removeBadge.onPress = { [weak self] in self?.area.edit(.remove(instance: tile.instance)) }
            tileViews[tile.instance] = view
            addSubview(view, positioned: .below, relativeTo: editBar)
            view.frame = frame(of: tile.instance) ?? .zero
            fadeIn(view, animated: animated)
        }
        for (instance, view) in tileViews where !live.contains(instance) {
            tileViews[instance] = nil
            fadeOut(view, animated: animated)
        }
        for view in tileViews.values { view.isEditing = area.isEditing }
        editBar.isHidden = !area.isEditing
        if area.isEditing, galleryPending, window != nil { openGallery() }
        // An open gallery follows the list (a widget installed or removed while it shows).
        if galleryOpened { gallery.follow(relativeTo: self) }
        layoutTiles(animated: animated)
        onContentSizeChange?()
        updateVisibility()
    }

    /// The tiles in the order shown (the drag's while one is lifted).
    var shownTiles: [AppWidgetTile] { drag?.order ?? area.tiles }

    /// Tile `instance`'s frame in the current layout.
    func frame(of instance: String) -> CGRect? {
        let tiles = shownTiles
        guard let index = tiles.firstIndex(where: { $0.instance == instance }) else { return nil }
        let frames = grid.layout(tiles.map(\.size), width: bounds.width).frames
        return frames.indices.contains(index) ? frames[index] : nil
    }

    /// The edit bar's height when it shows.
    private var editBarHeight: CGFloat { area.isEditing ? ceil(addButton.fittingSize.height) + Metrics.space2 : 0 }

    public func preferredHeight(width: CGFloat) -> CGFloat {
        let tiles = grid.layout(area.tiles.map(\.size), width: width).height
        let bar = editBarHeight
        guard tiles > 0 || bar > 0 else { return 0 }
        return tiles + bar + Metrics.space2
    }

    public override func layout() {
        super.layout()
        layoutTiles(animated: false)
    }

    func layoutTiles(animated: Bool) {
        let tiles = shownTiles
        let layout = grid.layout(tiles.map(\.size), width: bounds.width)
        let place = {
            for (tile, frame) in zip(tiles, layout.frames) {
                guard let view = self.tileViews[tile.instance], tile.instance != self.drag?.instance else { continue }
                if animated { view.animator().frame = frame } else { view.frame = frame }
            }
        }
        if animated {
            Motion.sidebar.animate(.move, in: self, place)
        } else {
            place()
        }
        let barTop = layout.height + (layout.height > 0 ? Metrics.space2 : 0)
        editBar.frame = CGRect(x: grid.inset, y: barTop, width: max(0, bounds.width - 2 * grid.inset),
                               height: ceil(addButton.fittingSize.height))
    }

    /// A new tile fades in (Reduce Motion: a crossfade; motion off: at once).
    private func fadeIn(_ view: NSView, animated: Bool) {
        guard animated, Motion.sidebar.canAnimate(in: self) else { return }
        view.alphaValue = 0
        Motion.sidebar.animate(.fadeIn, in: self, { view.animator().alphaValue = 1 })
    }

    /// A removed tile fades out, then leaves.
    private func fadeOut(_ view: NSView, animated: Bool) {
        guard animated else { return view.removeFromSuperview() }
        Motion.sidebar.animate(.fadeOut, in: self, { view.animator().alphaValue = 0 }, completion: { [weak view] in
            view?.removeFromSuperview()
        })
    }

    // MARK: Edit mode

    @objc func endEditing() {
        gallery.close()
        area.isEditing = false
    }

    @objc func addWidget() { openGallery() }

    /// Opens the Add Widget gallery under the area (in edit mode); asked for before the area is in
    /// a window, it opens once it is.
    public func openGallery() {
        guard let window, window.isVisible else {
            // Edit mode shows the area (also with no tile placed); the gallery opens once it is in a window.
            galleryPending = true
            area.isEditing = true
            return
        }
        galleryPending = false
        galleryOpened = true
        area.isEditing = true
        gallery.show(relativeTo: self)
    }

    // MARK: Visibility

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let sightWindow, sightWindow !== window { FrameScheduler.unfollowSight(of: sightWindow, owner: self) }
        sightWindow = window
        if let window { FrameScheduler.followSight(of: window, owner: self) { [weak self] in self?.updateVisibility() } }
        if window != nil, galleryPending { openGallery() }
        updateVisibility()
    }

    public override func viewDidHide() {
        super.viewDidHide()
        updateVisibility()
    }

    public override func viewDidUnhide() {
        super.viewDidUnhide()
        updateVisibility()
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateVisibility()
    }

    /// Reports each tile shown or hidden to the area (which sends only changes).
    func updateVisibility() {
        let windowShows = window.map { $0.occlusionState.contains(.visible) && !$0.isMiniaturized } ?? false
        let shows = windowShows && !isHiddenOrHasHiddenAncestor
        for (instance, view) in tileViews {
            area.setVisible(shows && !view.visibleRect.isEmpty, instance: instance)
        }
    }
}
