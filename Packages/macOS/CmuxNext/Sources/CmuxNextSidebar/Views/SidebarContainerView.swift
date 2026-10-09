public import AppKit
public import CmuxNextDesign
import Observation

/// The sidebar: clear over the window's one backdrop (the solid surface
/// token, or the root material and its tint), with no fill, panel, border
/// or seam (plans/cmux-next/windows.md). It owns its width.
///
/// Pin the edge of `side` (leading by default), top, and bottom; the view
/// animates its own width constraint between the user's width
/// (`SidebarModel.presentation == .shown`) and 0 (`.hidden`), and follows
/// live resizing through the handle on the edge facing the content.
/// Neighbors should attach to that edge so they follow and reach the window
/// edge when the sidebar hides.
///
/// While the width animates, the sidebar content keeps its full width and
/// slides out past the window edge (a clip view hides the overflow), so
/// rows never reflow mid-animation. Once hidden, the content is
/// `isHidden`: it cannot hold focus, take drops or appear to VoiceOver.
public final class SidebarContainerView: NSView {
    public let sidebarView: SidebarView
    public let model: SidebarModel
    /// The width constraint this view drives. Do not add another.
    public private(set) var widthConstraint: NSLayoutConstraint!

    /// Clips the sliding panel to the container's (animating) width.
    private let clip = NSView()
    /// Holds the sidebar at `model.width`, pinned to the clip's edge that
    /// faces the content (`side`).
    private let panel = NSView()
    private var panelWidth: NSLayoutConstraint!
    let handle: SidebarResizeHandle
    private var observation: Task<Void, Never>?
    /// Width the constraint is at or animating to. The animator reports
    /// intermediate constants, so compare against this instead.
    private var targetWidth: CGFloat
    /// Bumped per width animation; a stale completion does nothing.
    private var animationGeneration = 0

    /// The window edge this sidebar sits on (`sidebar.side`, R109): the
    /// resize handle and the slide-out follow it.
    public var side: SidebarSide = .left {
        didSet { if side != oldValue { applySide() } }
    }
    /// The panel and handle pins of each side (`applySide`).
    var sidePins: [SidebarSide: [NSLayoutConstraint]] = [:]

    /// Dragging the resize edge narrower than this hides the sidebar
    /// (there is no intermediate width below `Metrics.sidebarMinWidth`).
    public static var hideThreshold: CGFloat { Metrics.sidebarMinWidth / 2 }


    public init(model: SidebarModel) {
        self.model = model
        sidebarView = SidebarView(model: model)
        handle = SidebarResizeHandle()
        targetWidth = model.displayWidth
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        clip.wantsLayer = true
        clip.layer?.masksToBounds = true
        for view in [clip, panel, sidebarView, handle] { view.translatesAutoresizingMaskIntoConstraints = false }
        panel.addSubview(sidebarView)
        clip.addSubview(panel)
        addSubview(clip)
        addSubview(handle)
        widthConstraint = widthAnchor.constraint(equalToConstant: model.displayWidth)
        panelWidth = panel.widthAnchor.constraint(equalToConstant: model.width)
        NSLayoutConstraint.activate([
            widthConstraint,
            panelWidth,
            sidebarView.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            sidebarView.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            sidebarView.topAnchor.constraint(equalTo: panel.topAnchor),
            sidebarView.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
            clip.leadingAnchor.constraint(equalTo: leadingAnchor),
            clip.trailingAnchor.constraint(equalTo: trailingAnchor),
            clip.topAnchor.constraint(equalTo: topAnchor),
            clip.bottomAnchor.constraint(equalTo: bottomAnchor),
            panel.topAnchor.constraint(equalTo: clip.topAnchor),
            panel.bottomAnchor.constraint(equalTo: clip.bottomAnchor),
            handle.topAnchor.constraint(equalTo: topAnchor),
            handle.bottomAnchor.constraint(equalTo: bottomAnchor),
            handle.widthAnchor.constraint(equalToConstant: Metrics.dividerHitWidth),
        ])
        sidePins = Self.pins(panel: panel, clip: clip, handle: handle, in: self)
        NSLayoutConstraint.activate(sidePins[side] ?? [])
        panel.isHidden = model.isHidden
        handle.isHidden = model.isHidden
        handle.restingLineWidth = Metrics.sidebarBorderWidth
        handle.onDrag = { [weak self] phase in self?.handleDrag(phase) }
        observe()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    isolated deinit {
        observation?.cancel()
    }

    override public func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applySurfaceFill()
    }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applySurfaceFill()
    }

    /// Clear over the window's backdrop, or the user's sidebar background
    /// (`appearance.surfaces.sidebar`, `Palette.surfaceOverride`).
    private func applySurfaceFill() {
        clip.layer?.backgroundColor = performWithTheme { Palette.surfaceOverride(.sidebar)?.cgColor }
    }

    // MARK: Public API

    /// Restores saved state without animating (window creation, relaunch).
    public func restore(width: CGFloat?, presentation: SidebarPresentation) {
        if let width { model.width = width }
        model.presentation = presentation
        animationGeneration += 1
        snap()
    }

    /// Starts inline rename of a workspace, showing the sidebar first when
    /// it is hidden (the rename field lives in the list).
    public func beginRename(workspace id: WorkspaceID) {
        revealForEditing()
        sidebarView.beginRename(workspace: id)
    }

    /// The group whose name is being edited, if any (cx-rcby).
    public var editingGroup: GroupID? {
        if case let .group(id)? = sidebarView.list.inlineRename.session?.key { return id }
        return nil
    }

    /// Starts inline rename of a group, showing the sidebar first when it
    /// is hidden.
    public func beginRename(group id: GroupID) {
        revealForEditing()
        sidebarView.beginRename(group: id)
    }

    /// Shows a hidden sidebar and lays its rows out now, so a rename field
    /// can attach to a row in the same turn. The width still animates.
    private func revealForEditing() {
        guard model.isHidden else { return }
        model.presentation = .shown
        apply()
        panel.layoutSubtreeIfNeeded()
    }

    // MARK: Resize

    private var liveStartWidth: CGFloat = 0

    private func handleDrag(_ phase: SidebarResizeHandle.Phase) {
        switch phase {
        case .began:
            liveStartWidth = model.width
        case let .changed(dx):
            guard !model.isHidden else { return }
            // A right sidebar widens as its leading edge moves left.
            let proposed = liveStartWidth + (side == .left ? dx : -dx)
            if proposed < Self.hideThreshold {
                // Hide outright and come back at the width the drag began at.
                handle.endDrag()
                model.width = liveStartWidth
                model.presentation = .hidden
            } else {
                model.width = proposed
                panelWidth.constant = model.width
                targetWidth = model.width
                widthConstraint.constant = model.width
            }
        case .ended:
            break
        }
    }

    // MARK: Observation

    private func observe() {
        let model = model
        observation = Task { [weak self] in
            for await (_, _, defaultWidth, border) in Observations({
                // The default width token is tracked so a settings change
                // resizes live.
                (model.presentation, model.width, Metrics.sidebarWidth, Metrics.sidebarBorderWidth)
            }) {
                self?.handle.restingLineWidth = border
                self?.followDefaultWidth(defaultWidth)
                self?.apply()
            }
        }
    }

    private var lastDefaultWidth: CGFloat?

    /// When the user changes the sidebar width setting, adopt it.
    private func followDefaultWidth(_ value: CGFloat) {
        defer { lastDefaultWidth = value }
        guard let last = lastDefaultWidth, last != value else { return }
        model.width = value
    }

    /// The width animation lays the sidebar out each frame and a hide ends
    /// it: views slide or hide under a still pointer, and hover follows
    /// (cx-3wu5).
    override public func layout() {
        super.layout()
        PointerHover.refresh(in: window)
    }

    /// Sets every constraint and visibility for the model without animating.
    private func snap() {
        targetWidth = model.displayWidth
        widthConstraint.constant = targetWidth
        panelWidth.constant = model.width
        panel.isHidden = model.isHidden
        handle.isHidden = model.isHidden
    }

    /// Animates to the model's presentation with the appear / disappear tokens (instant with
    /// Reduce Motion). Idempotent: a repeat call for the same target does
    /// nothing, so the observation and a synchronous caller can both run it.
    private func apply() {
        let hidden = model.isHidden
        let target = model.displayWidth
        panelWidth.constant = model.width
        handle.isHidden = hidden
        if handle.isDragging, !hidden {
            targetWidth = target
            widthConstraint.constant = target
            return
        }
        guard targetWidth != target else { return }
        targetWidth = target
        if !hidden { panel.isHidden = false }
        animationGeneration += 1
        let generation = animationGeneration
        // Animate only the constraint: descendants re-lay out each frame at
        // their real size. Forcing layout inside the animation block would
        // make every subview frame an implicit animation whose completion
        // overwrites later layout.
        // Constraint animators ignore SwiftUI springs (they fall back to
        // AppKit's 0.25 s default), so this is the tokens' timed equivalent.
        // A toggle mid-animation starts from the constant on screen.
        Motion.animateTimed(hidden ? .disappear : .appear, in: self, {
            Motion.animator(widthConstraint, in: self).constant = target
        }, completion: { [weak self] in
            guard let self, generation == self.animationGeneration, self.model.isHidden else { return }
            self.panel.isHidden = true
            PointerHover.refresh(in: self.window)
        })
    }
}

/// Strip on the sidebar's edge facing the content that resizes it. Invisible until
/// the pointer is over it; then a hairline fades in (and stays while
/// dragging), so the edge never shows as a seam at rest.
final class SidebarResizeHandle: NSView {
    enum Phase {
        case began
        case changed(CGFloat)
        case ended
    }

    var onDrag: ((Phase) -> Void)?
    private(set) var isDragging = false { didSet { updateLine() } }
    /// Set by the hover owner (`PointerHover`, cx-3wu5).
    private(set) var isHovered = false { didSet { updateLine() } }
    private var pointerHover: PointerHover?
    private var startX: CGFloat = 0
    private let line = CALayer()

    /// Width of the line at rest (`sidebar.border`); 0 shows it only on
    /// hover or while dragging.
    var restingLineWidth: CGFloat = 0 {
        didSet {
            guard restingLineWidth != oldValue else { return }
            needsLayout = true
            updateLine()
        }
    }

    /// The hairline shows at rest when the sidebar border is on, else only
    /// on hover or while dragging.
    var isLineVisible: Bool { isHovered || isDragging || restingLineWidth > 0 }

    /// The drawn width: the border's, else the divider hairline.
    var lineWidth: CGFloat { restingLineWidth > 0 ? restingLineWidth : Metrics.lineWidth(Metrics.dividerThickness) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        line.opacity = 0
        layer?.addSublayer(line)
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
        setAccessibilityLabel(Strings.resize)
        pointerHover = PointerHover(self) { [weak self] hovering in self?.setHovered(hovering) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .columnResize)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let width = lineWidth
        line.frame = CGRect(x: (bounds.width - width) / 2, y: 0, width: width, height: bounds.height)
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyLineTheme()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyLineTheme()
    }

    /// The hairline's color and width both go through the border metric
    /// (`Palette.separator`, `Metrics.lineWidth`): a borders change repaints
    /// here, and the relayout picks up the width.
    private func applyLineTheme() {
        performWithTheme { line.backgroundColor = Palette.separator.cgColor }
        needsLayout = true
    }

    func setHovered(_ hovered: Bool) { isHovered = hovered }

    /// Hidden with the sidebar under a still pointer: no exit comes.
    override func viewDidHide() {
        super.viewDidHide()
        pointerHover?.refresh()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        pointerHover?.refresh()
    }

    private func updateLine() {
        let target: Float = isLineVisible ? 1 : 0
        guard line.opacity != target else { return }
        Motion.set(line, "opacity", to: target, fade: .hover)
    }

    override func mouseDown(with event: NSEvent) {
        isDragging = true
        startX = event.locationInWindow.x
        onDrag?(.began)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        onDrag?(.changed(event.locationInWindow.x - startX))
    }

    /// Ends the drag early (it hid the sidebar); later drag events for
    /// this press are ignored.
    func endDrag() {
        isDragging = false
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging else { return }
        isDragging = false
        onDrag?(.ended)
    }
}
