public import AppKit
public import CmuxNextDesign
import CmuxNextCompat
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
    /// Built in init (lazy because it anchors self; no IUO).
    public private(set) lazy var widthConstraint: NSLayoutConstraint = widthAnchor.constraint(equalToConstant: model.displayWidth)

    /// Clips the sliding panel to the container's (animating) width.
    private let clip = NSView()
    /// Holds the sidebar at `model.width`, pinned to the clip's edge that
    /// faces the content (`side`).
    private let panel = NSView()
    private lazy var panelWidth: NSLayoutConstraint = panel.widthAnchor.constraint(equalToConstant: model.width)
    let handle: SidebarResizeHandle
    private var observation: Task<Void, Never>?
    /// Width the constraint is at or animating to. The animator reports
    /// intermediate constants, so compare against this instead.
    private var targetWidth: CGFloat
    /// Bumped per width animation; a stale completion does nothing.
    private var animationGeneration = 0
    /// Completion gates for the optional opacity leg. Width and opacity use
    /// separate tokens, so a reduced-motion fade can finish after the width
    /// snaps without exposing a panel that is not ready to be hidden.
    private var widthCompletedGeneration: Int?
    private var fadeCompletedGeneration: Int?
    /// The collapse prototype used by the current transition. Keeping it
    /// alongside the width target lets a Debug Settings change retarget a
    /// transition already in flight without changing the default geometry.
    private var targetCollapseMotion: SidebarCollapseMotionVariant

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
        targetCollapseMotion = SidebarTunables.collapseMotion.value
        widthCompletedGeneration = nil
        fadeCompletedGeneration = nil
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        clip.wantsLayer = true
        clip.layer?.masksToBounds = true
        for view in [clip, panel, sidebarView, handle] { view.translatesAutoresizingMaskIntoConstraints = false }
        panel.addSubview(sidebarView)
        clip.addSubview(panel)
        addSubview(clip)
        addSubview(handle)
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

    // cx-t7hu: not an isolated deinit; its runtime hop traps when released inside an action's task-local scope.
    nonisolated deinit {
        guard Thread.isMainThread else { return } // main-proof: returns off the main thread
        MainActor.assumeIsolated {
            observation?.cancel()
        }
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
            for await (_, _, defaultWidth, border, _) in ObservationStream({
                // The default width token is tracked so a settings change
                // resizes live. The collapse prototype is tracked here too,
                // so Debug Settings retargets an in-flight transition.
                (model.presentation, model.width, Metrics.sidebarWidth, Metrics.sidebarBorderWidth,
                 SidebarTunables.collapseMotion.value)
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
        targetCollapseMotion = SidebarTunables.collapseMotion.value
        widthConstraint.constant = targetWidth
        panelWidth.constant = model.width
        panel.isHidden = model.isHidden
        panel.alphaValue = 1
        handle.isHidden = model.isHidden
    }

    /// Animates to the model's presentation with the appear / disappear tokens (instant with
    /// Reduce Motion). Idempotent: a repeat call for the same target does
    /// nothing, so the observation and a synchronous caller can both run it.
    private func apply() {
        let hidden = model.isHidden
        let target = model.displayWidth
        let collapseMotion = SidebarTunables.collapseMotion.value
        panelWidth.constant = model.width
        handle.isHidden = hidden
        if handle.isDragging, !hidden {
            targetWidth = target
            targetCollapseMotion = collapseMotion
            widthConstraint.constant = target
            return
        }
        guard targetWidth != target || targetCollapseMotion != collapseMotion else { return }
        targetWidth = target
        targetCollapseMotion = collapseMotion
        if !hidden { panel.isHidden = false }
        // The slide-and-fade prototype starts an expansion transparent and
        // lets the same timed transition reveal it. Slide keeps the current
        // opaque panel behavior, including when a user switches variants
        // while the sidebar is already visible.
        if !hidden { panel.alphaValue = collapseMotion.fadesPanel ? 0 : 1 }
        animationGeneration += 1
        let generation = animationGeneration
        widthCompletedGeneration = nil
        fadeCompletedGeneration = collapseMotion.fadesPanel ? nil : generation
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
            guard let self, generation == self.animationGeneration else { return }
            self.widthCompletedGeneration = generation
            self.finishCollapseIfReady(generation: generation, hidden: hidden, fadesPanel: collapseMotion.fadesPanel)
        })

        // Keep the width's existing appear/disappear timing, but let the
        // prototype use the short fade tokens. This makes slideFade read as
        // a quick reveal over the structural slide instead of extending the
        // opacity animation to the sidebar's full travel time.
        if collapseMotion.fadesPanel {
            Motion.animateTimed(hidden ? .fadeOut : .fadeIn, in: self, {
                panel.animator().alphaValue = hidden ? 0 : 1
            }, completion: { [weak self] in
                guard let self, generation == self.animationGeneration else { return }
                self.fadeCompletedGeneration = generation
                self.finishCollapseIfReady(generation: generation, hidden: hidden, fadesPanel: true)
            })
        }
    }

    /// Hides a collapsed panel only after each active leg reaches its target.
    /// Width normally finishes last; the explicit gate also keeps Reduce
    /// Motion's instant width snap from racing the short opacity fade.
    private func finishCollapseIfReady(generation: Int, hidden: Bool, fadesPanel: Bool) {
        guard hidden, generation == animationGeneration, model.isHidden,
              widthCompletedGeneration == generation,
              !fadesPanel || fadeCompletedGeneration == generation else { return }
        panel.alphaValue = fadesPanel ? 0 : 1
        panel.isHidden = true
        PointerHover.refresh(in: window)
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
    /// on hover or while dragging, and never as hover feedback beside the
    /// curved main pane: the card's edge is the seam there. The hit area and
    /// the resize cursor stay.
    var isLineVisible: Bool { restingLineWidth > 0 || ((isHovered || isDragging) && !Metrics.mainPaneCurved) }

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
        if #available(macOS 15, *) {
            addCursorRect(bounds, cursor: .columnResize)
        } else {
            addCursorRect(bounds, cursor: .resizeLeftRight)
        }
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

    /// A press here resizes the sidebar, also in the titlebar band: it never moves the window
    /// (`TitlebarDragPolicy`).
    override var mouseDownCanMoveWindow: Bool { false }

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
