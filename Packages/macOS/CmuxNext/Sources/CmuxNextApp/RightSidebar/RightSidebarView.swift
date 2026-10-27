import AppKit
import CmuxNextActions
import CmuxNextCompat
import CmuxNextDesign

/// The right sidebar's view: a bar of section icons under the window's top
/// row, the shown section below it, and a grab strip on the edge facing the
/// content that resizes it. A button runs its section's switch action (the
/// path the palette, `cmux action run` and MCP take). Section views are made
/// once per window and kept while hidden; with the app's sidebar section planner
/// (feature `memoryDiscardSidebarSections`) a hidden one goes when the planner says
/// and its next show makes it again from its `SidebarSectionState`. It
/// paints no ground: the window's shows through, the same under every section.
final class RightSidebarView: NSView {
    private let bar = NSStackView()
    private var buttons: [RightSidebarMode: NSButton] = [:]
    private var views: [RightSidebarMode: NSView] = [:]
    /// The app's sidebar section planner; nil keeps every section for good.
    private let planner: (any SidebarSectionPlanner)?
    /// The sections on the planner's discard, with what each released one showed.
    private lazy var releases = SidebarSectionReleases<RightSidebarMode, SidebarSectionState>(owner: "rightSidebar", planner: planner) { [weak self] mode in
        self?.views[mode].map(Self.state(of:))
    } drop: { [weak self] mode in
        self?.letGo(mode)
    }
    /// The scroll a section made again without its own state goes back to at the next layout.
    private var pendingScroll: (mode: RightSidebarMode, origin: CGPoint)?
    private(set) var shownMode: RightSidebarMode?
    /// The grab strip on the edge facing the content.
    let resizeHandle = RightSidebarResizeHandle(frame: .zero)
    /// A section icon's alpha while its section is not shown: the shown one is in full ink.
    static let idleButtonAlpha: CGFloat = 0.45
    /// The edge facing the content (`.minX` when the sidebar is on the window's right).
    var innerEdge: NSRectEdge = .minX {
        didSet {
            guard innerEdge != oldValue else { return }
            resizeHandle.edge = innerEdge
            needsLayout = true // invalidate: the sidebar changed sides (the guard above).
        }
    }
    /// A drag on the inner edge: the width it proposes, then nil when it ends.
    var onResize: (@MainActor (CGFloat?) -> Void)?
    private var dragStartWidth: CGFloat = 0
    /// The section bar's buttons, by section.
    var barButtons: [RightSidebarMode: NSButton] { buttons }
    /// The window's top row (traffic lights, the tab strip's height): the bar starts under it.
    var topInset: CGFloat = 0 { didSet { if topInset != oldValue { needsLayout = true } } }
    private let barHeight: CGFloat = 28
    private let makeSection: @MainActor (RightSidebarMode) -> NSView?
    private let run: @MainActor (ActionID) -> Void

    /// - Parameters:
    ///   - modes: The sections with a provider, in bar order.
    ///   - title: A section's button tooltip (its action's title).
    ///   - icon: A section's button image (``RightSidebarSections/icon(_:)``: made off the main thread; nil leaves
    ///     the button empty until ``setIcons(_:)``).
    ///   - makeSection: Makes a section's view the first time it shows.
    ///   - run: Runs an action (a button's switch action).
    ///   - planner: The app's sidebar section planner, which lets hidden sections go; nil keeps each for good.
    init(modes: [RightSidebarMode], title: (RightSidebarMode) -> String, icon: (RightSidebarMode) -> NSImage?,
         makeSection: @escaping @MainActor (RightSidebarMode) -> NSView?, run: @escaping @MainActor (ActionID) -> Void,
         planner: (any SidebarSectionPlanner)? = nil) {
        self.makeSection = makeSection
        self.run = run
        self.planner = planner
        super.init(frame: NSRect(x: 0, y: 0, width: RightSidebarModel.width, height: 400))
        bar.orientation = .horizontal
        bar.spacing = Metrics.space2
        bar.edgeInsets = NSEdgeInsets(top: 0, left: Metrics.space3, bottom: 0, right: Metrics.space3)
        for mode in modes {
            let button = NSButton(image: icon(mode) ?? NSImage(), target: self, action: #selector(pick(_:)))
            button.bezelStyle = .accessoryBarAction
            button.isBordered = false
            button.title = ""
            button.imagePosition = .imageOnly
            // Icons only: the shown section is the icon in full ink, no pressed-in bezel.
            button.setButtonType(.momentaryChange)
            button.alphaValue = Self.idleButtonAlpha
            button.themedToolTip = title(mode)
            button.setAccessibilityLabel(title(mode))
            button.identifier = NSUserInterfaceItemIdentifier(mode.rawValue)
            buttons[mode] = button
            bar.addArrangedSubview(button)
        }
        addSubview(bar)
        resizeHandle.onDrag = { [weak self] phase in self?.drag(phase) }
        addSubview(resizeHandle)
        setAccessibilityIdentifier("cmux.rightSidebar")
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    nonisolated override var isFlipped: Bool { true }

    /// Puts the section icons on their buttons when they land after the panel was built
    /// (``RightSidebarSections/whenIconsReady(_:)``).
    func setIcons(_ icons: [RightSidebarMode: NSImage]) {
        for (mode, button) in buttons { if let image = icons[mode] { button.image = image } }
    }

    @objc private func pick(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let mode = RightSidebarMode(rawValue: raw) else { return }
        run(mode.actionID)
    }

    /// Shows `mode`'s section (made now if new, or again from its record if it was let go); false when the mode
    /// has none.
    @discardableResult
    func show(_ mode: RightSidebarMode) -> Bool {
        let view: NSView
        let isNew = views[mode] == nil
        if let made = views[mode] {
            view = made
        } else {
            guard let made = makeSection(mode) else { return false }
            views[mode] = made
            view = made
            addSubview(made, positioned: .below, relativeTo: resizeHandle)
            if let record = releases.takeRecord(mode) { restore(record, in: made, mode: mode) }
        }
        for (other, shown) in views { shown.isHidden = other != mode }
        releases.show(mode, hiding: views.keys, isNew: isNew)
        for (other, button) in buttons {
            button.alphaValue = other == mode ? 1 : Self.idleButtonAlpha
            // No pressed-in state to read, so VoiceOver hears the shown section as selected.
            button.setAccessibilitySelected(other == mode)
        }
        shownMode = mode
        view.frame = contentFrame
        return true
    }

    /// The shown section's view.
    var shownSection: NSView? { shownMode.flatMap { views[$0] } }

    /// `mode`'s section view while it is made (tests and diagnostics).
    func sectionView(_ mode: RightSidebarMode) -> NSView? { views[mode] }

    /// The planner's release of hidden `mode`: its view goes, its record stays.
    private func letGo(_ mode: RightSidebarMode) {
        guard mode != shownMode else { return }
        views.removeValue(forKey: mode)?.removeFromSuperview()
    }

    /// What `view` shows now: its own state, else its first list's scroll.
    private static func state(of view: NSView) -> SidebarSectionState {
        (view as? SidebarSectionStateKeeping)?.sectionState ?? SidebarSectionState(scroll: firstScrollView(in: view)?.documentVisibleRect.origin)
    }

    /// The first scroll view under `view`, depth first: the list a section without its own state scrolls.
    private static func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for subview in view.subviews { if let found = firstScrollView(in: subview) { return found } }
        return nil
    }

    private func restore(_ record: SidebarSectionState, in view: NSView, mode: RightSidebarMode) {
        if let keeper = view as? SidebarSectionStateKeeping { return keeper.restoreSectionState(record) }
        guard let origin = record.scroll else { return }
        pendingScroll = (mode, origin)
        needsLayout = true // invalidate: the made-again section scrolls back once it has its frame.
    }

    private var contentFrame: NSRect {
        let top = topInset + barHeight
        return NSRect(x: 0, y: top, width: bounds.width, height: max(0, bounds.height - top))
    }

    override func layout() {
        super.layout()
        bar.frame = NSRect(x: 0, y: topInset, width: bounds.width, height: barHeight)
        shownSection?.frame = contentFrame
        if let pending = pendingScroll, pending.mode == shownMode, let section = shownSection {
            pendingScroll = nil
            // sync-layout: once per section made again, so its list has its size before it scrolls back.
            section.layoutSubtreeIfNeeded()
            if let scroll = Self.firstScrollView(in: section) {
                scroll.contentView.scroll(to: scroll.contentView.constrainBoundsRect(NSRect(origin: pending.origin, size: scroll.contentView.bounds.size)).origin)
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }
        let grab = RightSidebarResizeHandle.grabWidth
        resizeHandle.frame = NSRect(x: innerEdge == .minX ? 0 : bounds.width - grab, y: 0, width: grab, height: bounds.height)
    }

    private func drag(_ phase: RightSidebarResizeHandle.Phase) {
        switch phase {
        case .began:
            dragStartWidth = bounds.width
        case let .changed(dx):
            // Moving the inner edge away from the sidebar widens it.
            onResize?(dragStartWidth + (innerEdge == .minX ? -dx : dx))
        case .ended:
            onResize?(nil)
        }
    }
}
