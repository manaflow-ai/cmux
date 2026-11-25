public import AppKit
import CmuxNextCompat
public import CmuxNextDesignTokens

/// The one Cmd-F find pill: a Liquid Glass capsule (frosted before macOS 26, solid under Reduce
/// Transparency) with a magnifier, a field that searches as you type, the match count, an optional
/// match-case toggle, previous and next chevrons, and a close button.
///
/// Every native find surface uses it (the terminal over Ghostty search, the browser over the
/// engine's find-in-page), and the web pages draw its twin (`webviews/src/ui/FindPill.tsx`) from
/// the same ``FindPillMetrics``, so a find bar looks the same over every kind of pane. The pill
/// only draws and reports: its surface owns the search and answers with ``showCount(_:noMatches:canStep:)``.
///
/// ```swift
/// let pill = FindPillView(labels: labels, icons: icons, accessibilityPrefix: "cmux.terminal.find")
/// pill.onQueryChange = { find.updateQuery($0) }
/// pill.onCommand = { command in
///     switch command {
///     case .next: find.navigate(.next)
///     case .previous: find.navigate(.previous)
///     case .close: find.close()
///     }
/// }
/// pill.showCount("2 of 3", noMatches: false)
/// ```
///
/// Tests build one with any images and labels and drive it through ``handleFieldCommand(_:shift:)``,
/// ``simulateTyping(_:)`` and its buttons; no window is needed.
public final class FindPillView: NSView {
    /// Whether an arrow key-down belongs to the field editor's text-navigation path.
    ///
    /// The app dispatches key-downs before AppKit's field editor and menu routing. Keep this
    /// policy beside the shared find field so terminal and browser pills get the same treatment.
    public static func shouldForwardArrowKeyDown(keyCode: UInt16, flags: NSEvent.ModifierFlags,
                                                 hasMarkedText: Bool) -> Bool {
        guard !hasMarkedText, (123...126).contains(keyCode) else { return false }
        let normalizedFlags = flags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
        switch normalizedFlags {
        case [], [.shift], [.option], [.option, .shift], [.command], [.command, .shift]:
            return true
        default:
            return false
        }
    }

    /// Whether `responder` is the field editor currently editing this pill's query.
    public static func ownsFieldEditor(_ responder: NSResponder?) -> Bool {
        guard let editor = responder as? NSTextView, editor.isFieldEditor else { return false }
        if editor.delegate is FindPillView { return true }
        guard let field = editor.delegate as? NSTextField else { return false }
        var view: NSView? = field
        while let current = view {
            if current is FindPillView { return true }
            view = current.superview
        }
        return false
    }

    /// Sends an allowed arrow directly to the active field editor before AppKit offers menu
    /// equivalents. Returns true when this pill owned the event.
    public static func forwardArrowKeyDown(_ event: NSEvent, in window: NSWindow?) -> Bool {
        guard event.type == .keyDown, let responder = window?.firstResponder,
              let client = responder as? NSTextInputClient,
              ownsFieldEditor(responder),
              shouldForwardArrowKeyDown(keyCode: event.keyCode, flags: event.modifierFlags,
                                        hasMarkedText: client.hasMarkedText()) else { return false }
        responder.keyDown(with: event)
        return true
    }

    /// Called with the field's text on every edit the user makes (not when ``query`` is set).
    public var onQueryChange: ((String) -> Void)?
    /// Called for Return, Shift-Return, Escape and the three buttons.
    public var onCommand: ((FindPillCommand) -> Void)?
    /// Called with the new value when the user flips the match-case toggle.
    public var onMatchCaseChange: ((Bool) -> Void)?

    /// The capsule's material view (Liquid Glass, frosted, or solid).
    public let surface: OverlaySurfaceView
    /// Themes its caret, selection and placeholder in the pill's scope, focused or not.
    let field = ThemedTextField()
    private var typographyObservation: Task<Void, Never>?
    private let countLabel = ChromeLabel(labelWithString: "")
    private let icon = NSImageView()
    /// The previous and next chevrons, disabled while nothing matches.
    let stepButtons: [FindPillButton]
    private let closeButton: FindPillButton
    /// The match-case toggle; nil where the surface cannot match case.
    let matchCaseButton: FindPillButton?
    private let separators: [NSView]
    /// The count says nothing matches: drawn in the danger ink.
    private(set) var showsNoMatches = false
    /// The pill is shown or fading in (it stays unhidden while fading out).
    public private(set) var isPresented = false

    /// - Parameters:
    ///   - labels: The localized placeholder and button labels; a nil ``FindPillLabels/matchCase``
    ///     leaves the toggle out.
    ///   - icons: The magnifier and button images.
    ///   - accessibilityPrefix: Prefixes the field's and buttons' accessibility identifiers
    ///     (`<prefix>.field`, `.previous`, `.next`, `.close`, `.matchCase`), which UI tests use.
    public init(labels: FindPillLabels, icons: FindPillIcons, accessibilityPrefix: String) {
        surface = Glass.makeOverlayPanel(cornerRadius: FindPillMetrics.height / 2)
        let previous = FindPillButton(image: icons.previous, target: nil, action: #selector(previousClicked))
        let next = FindPillButton(image: icons.next, target: nil, action: #selector(nextClicked))
        stepButtons = [previous, next]
        closeButton = FindPillButton(image: icons.close, target: nil, action: #selector(closeClicked))
        matchCaseButton = labels.matchCase.map { _ in
            FindPillButton(image: nil, title: "Aa", toggle: true, target: nil, action: #selector(matchCaseClicked))
        }
        separators = (labels.matchCase == nil ? [0] : [0, 1]).map { _ in NSView() }
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        // Starts hidden: ``setPresented(_:)`` shows it.
        isHidden = true
        alphaValue = 0

        for (button, label, id) in [(previous, labels.previous, "previous"), (next, labels.next, "next"),
                                    (closeButton, labels.close, "close")] {
            button.target = self
            button.themedToolTip = label
            button.setAccessibilityLabel(label)
            button.setAccessibilityIdentifier("\(accessibilityPrefix).\(id)")
        }
        if let toggle = matchCaseButton, let label = labels.matchCase {
            toggle.target = self
            toggle.themedToolTip = label
            toggle.setAccessibilityLabel(label)
            toggle.setAccessibilityIdentifier("\(accessibilityPrefix).matchCase")
        }

        field.placeholderString = labels.placeholder
        field.setAccessibilityLabel(labels.placeholder)
        field.setAccessibilityIdentifier("\(accessibilityPrefix).field")
        field.isBordered = false
        field.drawsBackground = false
        field.fill = { .clear }
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.font = Typography.system(.default, size: TypeScale.body)
        field.delegate = self

        countLabel.font = Typography.system(.monospacedDigit, size: TypeScale.detail, weight: .regular)
        countLabel.alignment = .right
        countLabel.setContentHuggingPriority(.required, for: .horizontal)
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        icon.image = icons.search
        icon.setContentHuggingPriority(.required, for: .horizontal)
        for separator in separators {
            separator.wantsLayer = true
            separator.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                separator.widthAnchor.constraint(equalToConstant: 1),
                separator.heightAnchor.constraint(equalToConstant: FindPillMetrics.separatorHeight),
            ])
        }

        var views: [NSView] = [icon, field, countLabel, separators[0]]
        if let toggle = matchCaseButton { views += [toggle, separators[1]] }
        views += stepButtons + [closeButton]
        let stack = NSStackView(views: views)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.spacing = 2
        stack.setCustomSpacing(8, after: icon)
        for separator in separators {
            stack.setCustomSpacing(4, after: separator)
            if let index = views.firstIndex(of: separator), index > 0 { stack.setCustomSpacing(4, after: views[index - 1]) }
        }
        stack.edgeInsets = NSEdgeInsets(top: 0, left: FindPillMetrics.leadingPadding, bottom: 0,
                                        right: FindPillMetrics.trailingPadding)

        surface.contentView.addSubview(stack)
        addSubview(surface)
        // Preferred width: a narrow pane narrows the field.
        let fieldWidth = field.widthAnchor.constraint(equalToConstant: FindPillMetrics.fieldWidth)
        fieldWidth.priority = NSLayoutConstraint.Priority(450)
        NSLayoutConstraint.activate([
            fieldWidth,
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            surface.leadingAnchor.constraint(equalTo: leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: trailingAnchor),
            surface.topAnchor.constraint(equalTo: topAnchor),
            surface.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: FindPillMetrics.height),
            countLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: FindPillMetrics.countMinWidth),
        ])
        showCount("", noMatches: false, canStep: false)
        // task-owner: the pill owns this one typography subscription and cancels it on deinit.
        typographyObservation = Task { [weak self] in
            for await _ in ObservationStream({ Typography.userScale }) {
                self?.applyTypography()
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    nonisolated deinit { typographyObservation?.cancel() }

    private func applyTypography() {
        field.font = Typography.system(.default, size: TypeScale.body)
        countLabel.font = Typography.system(.monospacedDigit, size: TypeScale.detail, weight: .regular)
        if let editor = field.currentEditor() { editor.font = field.font }
        needsLayout = true
    }

    // MARK: State

    /// The field's text. Setting it does not call ``onQueryChange``.
    public var query: String {
        get { field.stringValue }
        set { if field.stringValue != newValue { field.stringValue = newValue } }
    }

    /// Whether the match-case toggle is on (always false without one).
    public var matchCase: Bool {
        get { matchCaseButton?.state == .on }
        set { matchCaseButton?.state = newValue ? .on : .off }
    }

    /// The count label's text.
    public var countText: String { countLabel.stringValue }

    /// True while the field has the keyboard.
    public var isEditing: Bool { field.currentEditor() != nil }

    /// Shows the surface's answer.
    ///
    /// - Parameters:
    ///   - text: "2 of 3", "No matches", or empty while there is no query.
    ///   - noMatches: The query matched nothing: the count reads in the danger ink, as an answer.
    ///   - canStep: The chevrons work; nil keeps them enabled exactly when `text` is not empty and
    ///     something matched.
    public func showCount(_ text: String, noMatches: Bool, canStep: Bool? = nil) {
        if countLabel.stringValue != text {
            countLabel.stringValue = text
            superview?.needsLayout = true // hosts frame the pill to its fitting width
        }
        showsNoMatches = noMatches
        let enabled = canStep ?? (!text.isEmpty && !noMatches)
        for button in stepButtons where button.isEnabled != enabled { button.isEnabled = enabled }
        applyColors()
    }

    /// Gives the field the keyboard with its text selected, so a recovered query is typed over.
    public func focusField() {
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    /// Shows or hides the pill: a quick fade (instant with animations off, under Reduce Motion
    /// a crossfade only, per `MotionPolicy`).
    public func setPresented(_ presented: Bool) {
        guard presented != isPresented else { return }
        isPresented = presented
        if presented {
            isHidden = false
            Motion.overlays.animate(.fadeIn, in: self) { animator().alphaValue = 1 }
        } else {
            Motion.overlays.animate(.fadeOut, in: self, { animator().alphaValue = 0 }, completion: { [weak self] in
                // Reopened while fading out: stay visible.
                guard let self, !self.isPresented else { return }
                self.isHidden = true
            })
        }
    }

    /// Runs `command` as if its key or button were used.
    public func perform(_ command: FindPillCommand) {
        onCommand?(command)
    }

    // MARK: Theme

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyColors()
    }

    private func applyColors() {
        performWithTheme {
            icon.contentTintColor = Palette.textSecondary
            countLabel.textColor = showsNoMatches ? Palette.danger : Palette.textSecondary
            field.textColor = Palette.textPrimary
            for separator in separators { separator.layer?.backgroundColor = Palette.separator.cgColor }
            surface.applyTheme()
        }
        for button in stepButtons + [closeButton] { button.applyColors() }
        matchCaseButton?.applyColors()
    }

    // MARK: Input

    @objc private func previousClicked() { perform(.previous) }
    @objc private func nextClicked() { perform(.next) }
    @objc private func closeClicked() { perform(.close) }
    @objc private func matchCaseClicked() { onMatchCaseChange?(matchCase) }

    /// The field's Return, Shift-Return and Escape; false for any other editing command.
    func handleFieldCommand(_ selector: Selector, shift: Bool) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)): perform(shift ? .previous : .next)
        case #selector(NSResponder.cancelOperation(_:)): perform(.close)
        default: return false
        }
        return true
    }

    /// Types `text` into the field as the user would (tests, automation).
    public func simulateTyping(_ text: String) {
        field.stringValue = text
        fieldChanged()
    }

    private func fieldChanged() {
        onQueryChange?(field.stringValue)
    }
}

extension FindPillView: NSTextFieldDelegate {
    public func controlTextDidChange(_ notification: Notification) {
        fieldChanged()
    }

    public func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        handleFieldCommand(selector, shift: NSApp.currentEvent?.modifierFlags.contains(.shift) == true)
    }
}
