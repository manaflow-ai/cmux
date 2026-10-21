import AppKit
import CmuxNextActions
import CmuxNextDesign

/// The right sidebar's view: a bar of section buttons under the window's top
/// row, and the shown section below it. A button runs its section's switch
/// action (the path the palette, `cmux action run` and MCP take). Section
/// views are made once per window and kept while hidden.
final class RightSidebarView: NSView {
    private let bar = NSStackView()
    private var buttons: [RightSidebarMode: NSButton] = [:]
    private var views: [RightSidebarMode: NSView] = [:]
    private(set) var shownMode: RightSidebarMode?
    /// The window's top row (traffic lights, the tab strip's height): the bar starts under it.
    var topInset: CGFloat = 0 { didSet { if topInset != oldValue { needsLayout = true } } }
    private let barHeight: CGFloat = 28
    private let makeSection: @MainActor (RightSidebarMode) -> NSView?
    private let run: @MainActor (ActionID) -> Void

    /// - Parameters:
    ///   - modes: The sections with a provider, in bar order.
    ///   - title: A section's button tooltip (its action's title).
    ///   - makeSection: Makes a section's view the first time it shows.
    ///   - run: Runs an action (a button's switch action).
    init(modes: [RightSidebarMode], title: (RightSidebarMode) -> String,
         makeSection: @escaping @MainActor (RightSidebarMode) -> NSView?, run: @escaping @MainActor (ActionID) -> Void) {
        self.makeSection = makeSection
        self.run = run
        super.init(frame: NSRect(x: 0, y: 0, width: RightSidebarModel.width, height: 400))
        bar.orientation = .horizontal
        bar.spacing = Metrics.space2
        bar.edgeInsets = NSEdgeInsets(top: 0, left: Metrics.space3, bottom: 0, right: Metrics.space3)
        for mode in modes {
            let button = NSButton(image: NSImage(systemSymbolName: mode.symbol, accessibilityDescription: title(mode)) ?? NSImage(),
                                  target: self, action: #selector(pick(_:)))
            button.bezelStyle = .accessoryBarAction
            button.isBordered = false
            button.setButtonType(.pushOnPushOff)
            button.toolTip = title(mode)
            button.setAccessibilityLabel(title(mode))
            button.identifier = NSUserInterfaceItemIdentifier(mode.rawValue)
            buttons[mode] = button
            bar.addArrangedSubview(button)
        }
        addSubview(bar)
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
            addSubview(made)
        }
        for (other, shown) in views { shown.isHidden = other != mode }
        for (other, button) in buttons { button.state = other == mode ? .on : .off }
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
    }
}
