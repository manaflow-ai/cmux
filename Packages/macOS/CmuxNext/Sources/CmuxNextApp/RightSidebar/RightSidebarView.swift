import AppKit
import CmuxNextActions
import CmuxNextDesign

/// The right sidebar's view: a bar of section icons under the window's top
/// row, the shown section below it, and a grab strip on the edge facing the
/// content that resizes it. A button runs its section's switch action (the
/// path the palette, `cmux action run` and MCP take). Section views are made
/// once per window and kept while hidden. It paints no ground: the window's
/// shows through, the same under every section.
final class RightSidebarView: NSView {
    private let bar = NSStackView()
    private var buttons: [RightSidebarMode: NSButton] = [:]
    private var views: [RightSidebarMode: NSView] = [:]
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
            needsLayout = true
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
    ///   - icon: A section's button image (``RightSidebarSections/icon(_:)``: made off the main thread at launch).
    ///   - makeSection: Makes a section's view the first time it shows.
    ///   - run: Runs an action (a button's switch action).
    init(modes: [RightSidebarMode], title: (RightSidebarMode) -> String, icon: (RightSidebarMode) -> NSImage?,
         makeSection: @escaping @MainActor (RightSidebarMode) -> NSView?, run: @escaping @MainActor (ActionID) -> Void) {
        self.makeSection = makeSection
        self.run = run
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

    @objc private func pick(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let mode = RightSidebarMode(rawValue: raw) else { return }
        run(mode.actionID)
    }

    /// Shows `mode`'s section (made now if new); false when the mode has none.
    @discardableResult
    func show(_ mode: RightSidebarMode) -> Bool {
        let view: NSView
        if let made = views[mode] {
            view = made
        } else {
            guard let made = makeSection(mode) else { return false }
            views[mode] = made
            view = made
            addSubview(made, positioned: .below, relativeTo: resizeHandle)
        }
        for (other, shown) in views { shown.isHidden = other != mode }
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

    private var contentFrame: NSRect {
        let top = topInset + barHeight
        return NSRect(x: 0, y: top, width: bounds.width, height: max(0, bounds.height - top))
    }

    override func layout() {
        super.layout()
        bar.frame = NSRect(x: 0, y: topInset, width: bounds.width, height: barHeight)
        shownSection?.frame = contentFrame
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
