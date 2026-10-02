import AppKit
import CmuxNextDesign
import CmuxNextTerminalFind
import Observation

/// The inline find bar over a terminal's top-trailing corner: a field that
/// searches as you type, the match count, previous and next buttons, and a
/// close button. It renders ``TerminalFindController`` and sends every edit,
/// key and click to it.
final class TerminalFindBarView: NSView {
    private let find: TerminalFindController
    private let field = NSTextField()
    private let countLabel = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private var buttons: [NSButton] = []
    private var shownFocusRequest = 0
    /// The bar is shown or fading in (it stays unhidden while fading out).
    private var shown = false
    private var glass: OverlaySurfaceView?

    init(find: TerminalFindController) {
        self.find = find
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isHidden = true
        alphaValue = 0

        field.placeholderString = Self.placeholder
        field.setAccessibilityLabel(Self.placeholder)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.font = Typography.body
        field.delegate = self

        countLabel.font = .monospacedDigitSystemFont(ofSize: Typography.caption.pointSize, weight: .regular)
        countLabel.alignment = .right
        countLabel.setContentHuggingPriority(.required, for: .horizontal)
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        icon.image = Self.symbol("magnifyingglass")
        buttons = [
            button("chevron.up", label: Self.previousLabel, action: #selector(previousClicked)),
            button("chevron.down", label: Self.nextLabel, action: #selector(nextClicked)),
            button("xmark", label: Self.closeLabel, action: #selector(closeClicked)),
        ]

        let stack = NSStackView(views: [icon, field, countLabel] + buttons)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.spacing = Metrics.space1
        stack.setCustomSpacing(Metrics.space3, after: icon)
        stack.setCustomSpacing(Metrics.space3, after: countLabel)
        stack.edgeInsets = NSEdgeInsets(top: 0, left: Metrics.space4, bottom: 0, right: Metrics.space1)

        let content = NSView()
        content.addSubview(stack)
        let glass = Glass.makeOverlayPanel(content: content)
        addSubview(glass)
        self.glass = glass
        // Preferred width: a narrow pane narrows the field.
        let fieldWidth = field.widthAnchor.constraint(equalToConstant: Metrics.tabMaxWidth * 3 / 4)
        fieldWidth.priority = NSLayoutConstraint.Priority(450)
        NSLayoutConstraint.activate([
            fieldWidth,
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: Metrics.tabStripHeight),
            countLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: Metrics.tabMinWidth),
        ])
        observe()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyColors()
    }

    /// Cmd-G and Shift-Cmd-G while the field has the keyboard (app
    /// shortcuts skip a focused text input). With the terminal focused,
    /// Find Next and Find Previous arrive as registry actions instead.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard shown, field.currentEditor() != nil, let command = Self.command(for: event), command != .close else {
            return super.performKeyEquivalent(with: event)
        }
        run(command)
        return true
    }

    // MARK: Rendering

    /// Re-renders whenever the controller state it reads changes.
    private func observe() {
        withObservationTracking {
            render()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
    }

    private func render() {
        let presented = find.isPresented
        let query = find.query
        let count = find.count
        let focusRequest = find.focusRequest

        if field.stringValue != query { field.stringValue = query }
        countLabel.stringValue = Self.text(for: count)
        setPresented(presented)
        if presented, focusRequest != shownFocusRequest {
            shownFocusRequest = focusRequest
            window?.makeFirstResponder(field)
            field.currentEditor()?.selectAll(nil)
        }
    }

    private func setPresented(_ presented: Bool) {
        guard presented != shown else { return }
        shown = presented
        if presented {
            isHidden = false
            Motion.animate(.fadeIn) { animator().alphaValue = 1 }
        } else {
            Motion.animate(.fadeOut, { animator().alphaValue = 0 }, completion: { [weak self] in
                // Reopened while fading out: stay visible.
                guard let self, !self.shown else { return }
                self.isHidden = true
            })
        }
    }

    private func applyColors() {
        performWithTheme {
            icon.contentTintColor = Palette.textSecondary
            countLabel.textColor = Palette.textSecondary
            field.textColor = Palette.textPrimary
            for button in buttons { button.contentTintColor = Palette.textSecondary }
            glass?.applyTheme()
        }
    }

    // MARK: Actions

    private func run(_ command: TerminalFindKeyCommand) {
        switch command {
        case .next: find.navigate(.next)
        case .previous: find.navigate(.previous)
        case .close: find.close()
        }
    }

    @objc private func previousClicked() { find.navigate(.previous) }
    @objc private func nextClicked() { find.navigate(.next) }
    @objc private func closeClicked() { find.close() }

    private func button(_ symbol: String, label: String, action: Selector) -> NSButton {
        let button = NSButton(image: Self.symbol(symbol) ?? NSImage(), target: self, action: action)
        button.isBordered = false
        button.bezelStyle = .accessoryBarAction
        button.toolTip = label
        button.setAccessibilityLabel(label)
        return button
    }

    private static func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: Metrics.smallIconSize - 1, weight: .semibold))
    }

    private static func command(for event: NSEvent) -> TerminalFindKeyCommand? {
        var modifiers: TerminalFindKeyCommand.Modifiers = []
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.command) { modifiers.insert(.command) }
        return TerminalFindKeyCommand(key: event.charactersIgnoringModifiers ?? "", modifiers: modifiers)
    }

    // MARK: Strings

    private static func text(for count: TerminalFindCount) -> String {
        switch count {
        case .empty:
            return ""
        case .noMatches:
            return String(localized: "terminal.find.noMatches", defaultValue: "No matches", bundle: .module)
        case .position(let index, let total):
            return String(localized: "terminal.find.position", defaultValue: "\(index) of \(total)", bundle: .module)
        }
    }

    private static var placeholder: String {
        String(localized: "terminal.find.placeholder", defaultValue: "Find", bundle: .module)
    }

    private static var previousLabel: String {
        String(localized: "terminal.find.previous", defaultValue: "Previous Match", bundle: .module)
    }

    private static var nextLabel: String {
        String(localized: "terminal.find.next", defaultValue: "Next Match", bundle: .module)
    }

    private static var closeLabel: String {
        String(localized: "terminal.find.done", defaultValue: "Done", bundle: .module)
    }
}

extension TerminalFindBarView: NSTextFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        find.updateQuery(field.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) == true
        let key: String
        switch selector {
        case #selector(NSResponder.insertNewline(_:)): key = "\r"
        case #selector(NSResponder.cancelOperation(_:)): key = "\u{1b}"
        default: return false
        }
        guard let command = TerminalFindKeyCommand(key: key, modifiers: shift ? .shift : []) else { return false }
        run(command)
        return true
    }
}
