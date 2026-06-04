import CmuxMobileTerminalKit
import Foundation
import UIKit

final class TerminalInputTextView: UITextView {
    var onText: ((String) -> Void)?
    var onBackspace: (() -> Void)?
    var onEscapeSequence: ((Data) -> Void)?
    var onZoom: ((TerminalFontZoomDirection) -> Void)?
    var onHideKeyboard: (() -> Void)?
    var accessoryLayoutInsetsProvider: (() -> UIEdgeInsets)?
    /// The leftmost toolbar button. Toggles its glyph between dismiss-keyboard
    /// (when the keyboard is up) and show-keyboard (when down) via
    /// ``setKeyboardShown(_:)``.
    private weak var dismissButton: UIButton?
    /// The extracted input policy (DECOMPOSITION-PLAN §2c): owns the
    /// armed/sticky modifier machine and every committed-text / backspace /
    /// accessory-tap byte translation. This view is a dumb first responder
    /// that forwards events and dispatches the returned emissions.
    private let inputCoordinator = TerminalInputCoordinator()
    /// Root-constructed accessory-bar configuration (which shortcuts show,
    /// and in what order), injected by the hosting surface view.
    private let accessoryConfiguration: TerminalAccessoryConfiguration
    private var pendingDirectInsertMirrorText = ""

    /// Monotonic-ish tap timestamp for the reducer's double-tap window. Uses
    /// the same wall-clock source the legacy `Date()` comparisons used, so the
    /// 0.4s sticky promotion behaves identically.
    private static func tapNow() -> TimeInterval { Date().timeIntervalSinceReferenceDate }
    private static let directInsertMirrorTextLimit = 128

    override var canBecomeFirstResponder: Bool { true }

    override var keyCommands: [UIKeyCommand]? {
        guard markedTextRange == nil else { return nil }
        return TerminalHardwareKeyResolver.makeKeyCommands(
            target: self,
            action: #selector(handleHardwareKeyCommand(_:))
        )
    }

    private static let monokaiBarColor = UIColor(red: 0x27/255.0, green: 0x28/255.0, blue: 0x22/255.0, alpha: 1)
    private static let accessoryHorizontalInset: CGFloat = 16
    private static let accessoryButtonFont = UIFont.systemFont(ofSize: 14, weight: .medium)
    private static let accessoryButtonSymbolConfig = UIImage.SymbolConfiguration(pointSize: 14, weight: .medium)
    private static let accessoryButtonInsets = UIEdgeInsets(top: 5, left: 10, bottom: 5, right: 10)
    private static let accessoryButtonCornerRadius: CGFloat = 6
    private static let accessoryButtonHeight: CGFloat = 28
    private static let accessoryButtonMinWidth: CGFloat = 44
    private static let accessoryButtonNormalBackground = UIColor(white: 0.35, alpha: 1)
    private var accessoryBackgroundLeadingConstraint: NSLayoutConstraint?
    private var accessoryBackgroundTrailingConstraint: NSLayoutConstraint?
    private var accessoryDismissLeadingConstraint: NSLayoutConstraint?
    private var accessoryScrollTrailingConstraint: NSLayoutConstraint?

    private lazy var terminalAccessoryToolbar: UIView = {
        let container = UIView()
        container.backgroundColor = .clear
        container.frame = CGRect(x: 0, y: 0, width: 0, height: 44)

        let backgroundView = UIView()
        backgroundView.backgroundColor = Self.monokaiBarColor
        backgroundView.translatesAutoresizingMaskIntoConstraints = false

        // Pinned keyboard dismiss button on the left
        let dismissButton = UIButton(type: .system)
        let dismissConfig = UIImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        dismissButton.setImage(UIImage(systemName: "keyboard.chevron.compact.down", withConfiguration: dismissConfig), for: .normal)
        dismissButton.tintColor = UIColor(white: 0.7, alpha: 1)
        dismissButton.addTarget(self, action: #selector(handleHideKeyboard), for: .touchUpInside)
        dismissButton.accessibilityIdentifier = "terminal.inputAccessory.hideKeyboard"
        dismissButton.accessibilityLabel = String(localized: "terminal.input_accessory.hideKeyboard", defaultValue: "Hide Keyboard")
        dismissButton.translatesAutoresizingMaskIntoConstraints = false
        self.dismissButton = dismissButton

        // Scrollable action buttons
        let scrollView = UIScrollView()
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 6
        stack.alignment = .center

        stack.translatesAutoresizingMaskIntoConstraints = false
        accessoryStackView = stack
        populateAccessoryActions()
        scrollView.addSubview(stack)

        // Arrow nub for directional pad
        let nub = TerminalArrowNubView()
        nub.onArrowKey = { [weak self] data in
            self?.onEscapeSequence?(data)
        }
        nub.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(backgroundView)
        container.addSubview(dismissButton)
        container.addSubview(nub)
        container.addSubview(scrollView)

        let backgroundLeadingConstraint = backgroundView.leadingAnchor.constraint(equalTo: container.leadingAnchor)
        let backgroundTrailingConstraint = backgroundView.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        let dismissLeadingConstraint = dismissButton.leadingAnchor.constraint(
            equalTo: container.safeAreaLayoutGuide.leadingAnchor,
            constant: Self.accessoryHorizontalInset
        )
        let scrollTrailingConstraint = scrollView.trailingAnchor.constraint(
            equalTo: container.safeAreaLayoutGuide.trailingAnchor,
            constant: -Self.accessoryHorizontalInset
        )

        NSLayoutConstraint.activate([
            backgroundLeadingConstraint,
            backgroundTrailingConstraint,
            backgroundView.topAnchor.constraint(equalTo: container.topAnchor),
            backgroundView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            dismissLeadingConstraint,
            dismissButton.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            dismissButton.widthAnchor.constraint(equalToConstant: 32),

            nub.leadingAnchor.constraint(equalTo: dismissButton.trailingAnchor, constant: 6),
            nub.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            nub.widthAnchor.constraint(equalToConstant: 34),
            nub.heightAnchor.constraint(equalToConstant: 34),

            scrollView.leadingAnchor.constraint(equalTo: nub.trailingAnchor, constant: 6),
            scrollTrailingConstraint,
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -4),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -8),
            stack.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor, constant: -8),
        ])

        accessoryBackgroundLeadingConstraint = backgroundLeadingConstraint
        accessoryBackgroundTrailingConstraint = backgroundTrailingConstraint
        accessoryDismissLeadingConstraint = dismissLeadingConstraint
        accessoryScrollTrailingConstraint = scrollTrailingConstraint
        // The cmux iOS app always drives a macOS cmux surface, so default the
        // accessory to Mac modifiers: retitle Ctrl/Alt to ⌃/⌥ and insert the ⌘
        // button. `updateModifierLabels(isMacRemote:)` can still switch this if a
        // non-Mac remote is ever introduced.
        updateModifierLabels(isMacRemote: true)
        return container
    }()

    /// The terminal accessory bar (modifier keys, arrow nub, shortcut buttons).
    ///
    /// Formerly the keyboard `inputAccessoryView`; it is now docked as a
    /// persistent bottom bar by ``GhosttySurfaceView`` so it stays visible when
    /// the keyboard is dismissed and reserves space above the bottom TUI rows.
    /// Its buttons still target this text view, so the action wiring is intact
    /// regardless of where the view is hosted.
    var toolbarView: UIView { terminalAccessoryToolbar }

    private weak var accessoryStackView: UIStackView?
    // Strong reference — command button is not always in the stack's arrangedSubviews,
    // so nothing else retains it.
    private var commandAccessoryButton: UIButton?
    private var isMacRemote = false

    func updateAccessoryLayoutInsets() {
        let insets = accessoryLayoutInsetsProvider?() ?? .zero
        let leftInset = max(0, insets.left)
        let rightInset = max(0, insets.right)

        accessoryBackgroundLeadingConstraint?.constant = leftInset
        accessoryBackgroundTrailingConstraint?.constant = -rightInset
        accessoryDismissLeadingConstraint?.constant = Self.accessoryHorizontalInset + leftInset
        accessoryScrollTrailingConstraint?.constant = -(Self.accessoryHorizontalInset + rightInset)

        if accessoryStackView != nil {
            terminalAccessoryToolbar.setNeedsLayout()
            terminalAccessoryToolbar.layoutIfNeeded()
        }
    }

    /// The structural buttons pinned to the front of the bar, ahead of the
    /// user-configurable shortcuts. Command is created but kept out of the
    /// stack until ``applyModifierPresentation()`` inserts it for a Mac remote.
    private static let pinnedLeadingActions: [TerminalInputAccessoryAction] = [
        .control, .alternate, .command, .zoomOut, .zoomIn,
    ]

    /// Build (or rebuild) the bar's buttons: the pinned modifier/zoom controls
    /// followed by the user-configurable shortcuts in their saved order. Safe to
    /// call repeatedly; it clears the stack first.
    private func populateAccessoryActions() {
        guard let stack = accessoryStackView else { return }
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        commandAccessoryButton?.removeFromSuperview()
        commandAccessoryButton = nil

        let actions = Self.pinnedLeadingActions + accessoryConfiguration.enabledActions
        for action in actions {
            let button = makeAccessoryButton(for: action)
            // Command is Mac-only; kept out of the stack and inserted by
            // applyModifierPresentation() when driving a Mac remote.
            if action == .command {
                commandAccessoryButton = button
            } else {
                stack.addArrangedSubview(button)
            }
        }
    }

    @objc private func handleAccessoryConfigurationChanged() {
        // Only rebuild once the bar exists; otherwise the lazy build picks up
        // the new configuration on first use.
        guard accessoryStackView != nil else { return }
        populateAccessoryActions()
        applyModifierPresentation()
        terminalAccessoryToolbar.setNeedsLayout()
        terminalAccessoryToolbar.layoutIfNeeded()
    }

    func updateModifierLabels(isMacRemote: Bool) {
        guard self.isMacRemote != isMacRemote else { return }
        self.isMacRemote = isMacRemote
        applyModifierPresentation()
    }

    /// Retitle the modifier buttons for the current remote and insert/remove the
    /// command button. Split out of ``updateModifierLabels(isMacRemote:)`` so a
    /// configuration-driven rebuild can re-apply it without toggling the flag.
    private func applyModifierPresentation() {
        guard let stack = accessoryStackView else { return }
        for case let button as UIButton in stack.arrangedSubviews {
            guard let action = TerminalInputAccessoryAction(rawValue: button.tag) else { continue }
            button.setTitle(action.title(isMacRemote: isMacRemote), for: .normal)
        }
        // Insert/remove the command button based on whether this is a Mac terminal.
        // We manage it outside the normal loop because it's not always in arrangedSubviews.
        if let cmdButton = commandAccessoryButton {
            if isMacRemote {
                if cmdButton.superview == nil {
                    // Insert after alternate (index 2 in original enum order: ctrl, alt, cmd)
                    // Find the alt button's index in the current arrangedSubviews
                    var insertIndex = stack.arrangedSubviews.count
                    for (idx, view) in stack.arrangedSubviews.enumerated() {
                        if view.tag == TerminalInputAccessoryAction.alternate.rawValue {
                            insertIndex = idx + 1
                            break
                        }
                    }
                    stack.insertArrangedSubview(cmdButton, at: insertIndex)
                }
            } else {
                if cmdButton.superview != nil {
                    stack.removeArrangedSubview(cmdButton)
                    cmdButton.removeFromSuperview()
                }
            }
        }
        // Disarm command state if switching away from Mac remote (clears a
        // sticky lock too, matching the legacy unconditional setter).
        if !isMacRemote && inputCoordinator.isArmed(.command) {
            inputCoordinator.disarmAll()
            refreshAccessoryButtonStyles()
        }
    }

    init(accessoryConfiguration: TerminalAccessoryConfiguration) {
        self.accessoryConfiguration = accessoryConfiguration
        super.init(frame: .zero, textContainer: nil)
        backgroundColor = .clear
        textColor = .clear
        tintColor = .clear
        autocorrectionType = .no
        autocapitalizationType = .none
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        spellCheckingType = .no
        keyboardType = .default
        returnKeyType = .default
        textContainerInset = .zero
        // The accessory bar is no longer the keyboard's `inputAccessoryView`;
        // `GhosttySurfaceView` docks `toolbarView` persistently at the bottom so
        // it survives keyboard dismissal. Leaving `inputAccessoryView` nil means
        // the keyboard shows without its own accessory (the docked bar rides
        // above it via `keyboardLayoutGuide`).
        delegate = self
        text = ""
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAccessoryConfigurationChanged),
            name: TerminalAccessoryConfiguration.didChangeNotification,
            object: nil
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func insertText(_ text: String) {
        guard !text.isEmpty else { return }
        TerminalInputDebugLog.log("proxy.insertText text=\(TerminalInputDebugLog.textSummary(text)) composing=\(markedTextRange != nil)")
        if markedTextRange != nil {
            pendingDirectInsertMirrorText = ""
            super.insertText(text)
            return
        }
        rememberDirectInsertMirror(text)
        emitCommittedText(text, source: "insertText")
    }

    override func deleteBackward() {
        if markedTextRange != nil || hasText {
            super.deleteBackward()
            return
        }
        let resolution = inputCoordinator.resolveBackspace()
        refreshAccessoryButtonStyles()
        switch resolution {
        case .plainDelete:
            onBackspace?()
        case .emission(let emission):
            dispatch(emission)
        case .suppressed:
            break
        }
    }

    func simulateTextChangeForTesting(_ text: String, isComposing: Bool) {
        self.text = text
        handleTextChange(currentText: text, isComposing: isComposing)
    }

    func simulateHardwareKeyCommandForTesting(input: String, modifierFlags: UIKeyModifierFlags) -> Bool {
        handleHardwareKeyInput(input: input, modifierFlags: modifierFlags)
    }

    func simulateAccessoryActionForTesting(_ action: TerminalInputAccessoryAction) {
        resetStickyTapTimeForTesting(action)
        handleAccessoryAction(action)
    }

    private func resetStickyTapTimeForTesting(_ action: TerminalInputAccessoryAction) {
        guard action.isModifier else { return }
        inputCoordinator.clearDoubleTapWindow()
    }

    @objc
    private func handleHardwareKeyCommand(_ sender: UIKeyCommand) {
        guard let input = sender.input else { return }
        _ = handleHardwareKeyInput(input: input, modifierFlags: sender.modifierFlags)
    }

    @objc
    private func handleHideKeyboard() {
        onHideKeyboard?()
    }

    /// Swap the leftmost button between dismiss-keyboard (`shown == true`,
    /// chevron-down) and show-keyboard (`shown == false`, plain keyboard)
    /// glyphs, cross-dissolved, so it reads as a single keyboard toggle.
    func setKeyboardShown(_ shown: Bool) {
        guard let dismissButton else { return }
        let config = UIImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        let symbol = shown ? "keyboard.chevron.compact.down" : "keyboard"
        let image = UIImage(systemName: symbol, withConfiguration: config)
        UIView.transition(with: dismissButton, duration: 0.2, options: .transitionCrossDissolve) {
            dismissButton.setImage(image, for: .normal)
        }
        dismissButton.accessibilityLabel = shown
            ? String(localized: "terminal.input_accessory.hideKeyboard", defaultValue: "Hide Keyboard")
            : String(localized: "terminal.input_accessory.showKeyboard", defaultValue: "Show Keyboard")
    }

    @objc
    private func handleAccessoryButton(_ sender: Any) {
        guard let button = sender as? UIView,
              let action = TerminalInputAccessoryAction(rawValue: button.tag) else { return }
        handleAccessoryAction(action)
    }

    @discardableResult
    private func handleHardwareKeyInput(input: String, modifierFlags: UIKeyModifierFlags) -> Bool {
        guard let data = TerminalHardwareKeyResolver.data(input: input, modifierFlags: modifierFlags) else {
            return false
        }
        onEscapeSequence?(data)
        return true
    }

    private func makeAccessoryButton(for action: TerminalInputAccessoryAction) -> UIButton {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.tag = action.rawValue
        button.addTarget(self, action: #selector(handleAccessoryButton(_:)), for: .touchUpInside)
        button.accessibilityIdentifier = action.accessibilityIdentifier
        button.accessibilityLabel = action.accessibilityLabel
        button.titleLabel?.font = Self.accessoryButtonFont

        if let symbolName = action.symbolName {
            button.setImage(UIImage(systemName: symbolName), for: .normal)
            button.setPreferredSymbolConfiguration(Self.accessoryButtonSymbolConfig, forImageIn: .normal)
        } else {
            button.setTitle(action.title, for: .normal)
        }

        applyAccessoryButtonBaseStyle(button)
        return button
    }

    private func applyAccessoryButtonBaseStyle(_ button: UIButton) {
        button.contentEdgeInsets = Self.accessoryButtonInsets
        button.backgroundColor = Self.accessoryButtonNormalBackground
        button.setTitleColor(.white, for: .normal)
        button.tintColor = .white
        button.layer.cornerRadius = Self.accessoryButtonCornerRadius
        button.heightAnchor.constraint(equalToConstant: Self.accessoryButtonHeight).isActive = true
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.accessoryButtonMinWidth).isActive = true
    }

    private func handleAccessoryAction(_ action: TerminalInputAccessoryAction) {
        let resolution = inputCoordinator.resolveAccessoryAction(action, now: Self.tapNow())
        refreshAccessoryButtonStyles()
        switch resolution {
        case .none:
            break
        case .zoom(let direction):
            onZoom?(direction)
        case .emission(let emission):
            dispatch(emission)
        }
    }

    /// Routes one resolved emission to the matching send closure.
    private func dispatch(_ emission: TerminalInputEmission) {
        switch emission {
        case .sendText(let text):
            onText?(text)
        case .sendBytes(let bytes):
            onEscapeSequence?(bytes)
        }
    }

    private func refreshAccessoryButtonStyles() {
        guard let stack = accessoryStackView else { return }
        for case let button as UIButton in stack.arrangedSubviews {
            guard let action = TerminalInputAccessoryAction(rawValue: button.tag) else { continue }
            let armed = isAccessoryActionArmed(action)
            let sticky = isAccessoryActionSticky(action)
            if sticky {
                button.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.85)
                button.setTitleColor(.white, for: .normal)
                button.tintColor = .white
                button.layer.borderWidth = 2
                button.layer.borderColor = UIColor.white.cgColor
            } else if armed {
                button.backgroundColor = .systemBlue
                button.setTitleColor(.white, for: .normal)
                button.tintColor = .white
                button.layer.borderWidth = 0
            } else {
                button.backgroundColor = Self.accessoryButtonNormalBackground
                button.setTitleColor(.white, for: .normal)
                button.tintColor = .white
                button.layer.borderWidth = 0
            }
        }
    }

    private func handleTextChange(currentText: String, isComposing: Bool) {
        TerminalInputDebugLog.log("proxy.textChange text=\(TerminalInputDebugLog.textSummary(currentText)) composing=\(isComposing) pendingDirect=\(TerminalInputDebugLog.textSummary(pendingDirectInsertMirrorText))")
        if isComposing {
            pendingDirectInsertMirrorText = ""
        } else if !pendingDirectInsertMirrorText.isEmpty {
            if currentText == pendingDirectInsertMirrorText {
                TerminalInputDebugLog.log("proxy.textChange suppressed direct insert mirror text=\(TerminalInputDebugLog.textSummary(currentText))")
                pendingDirectInsertMirrorText = ""
                if text != "" {
                    text = ""
                }
                return
            }
            pendingDirectInsertMirrorText = ""
        }

        let result = TerminalTextInputPipeline.process(text: currentText, isComposing: isComposing)
        if let committedText = result.committedText {
            emitCommittedText(committedText, source: "textChange")
        }
        if text != result.nextBufferText {
            text = result.nextBufferText
        }
    }

    private func rememberDirectInsertMirror(_ insertedText: String) {
        pendingDirectInsertMirrorText.append(insertedText)
        if pendingDirectInsertMirrorText.count > Self.directInsertMirrorTextLimit {
            pendingDirectInsertMirrorText = String(
                pendingDirectInsertMirrorText.suffix(Self.directInsertMirrorTextLimit)
            )
        }
    }

    private func emitCommittedText(_ committedText: String, source: String) {
        TerminalInputDebugLog.log("proxy.emit source=\(source) text=\(TerminalInputDebugLog.textSummary(committedText))")
        let emission = inputCoordinator.resolveCommittedText(committedText)
        refreshAccessoryButtonStyles()
        dispatch(emission)
    }

    private func isAccessoryActionArmed(_ action: TerminalInputAccessoryAction) -> Bool {
        switch action {
        case .control: return inputCoordinator.isArmed(.control)
        case .alternate: return inputCoordinator.isArmed(.alternate)
        case .command: return inputCoordinator.isArmed(.command)
        case .shift: return inputCoordinator.isArmed(.shift)
        default: return false
        }
    }

    private func isAccessoryActionSticky(_ action: TerminalInputAccessoryAction) -> Bool {
        switch action {
        case .control: return inputCoordinator.isStickyOn(.control)
        case .alternate: return inputCoordinator.isStickyOn(.alternate)
        case .command: return inputCoordinator.isStickyOn(.command)
        case .shift: return inputCoordinator.isStickyOn(.shift)
        default: return false
        }
    }
}

extension TerminalInputTextView: UITextViewDelegate {
    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        TerminalInputDebugLog.log("proxy.shouldChange replacement=\(TerminalInputDebugLog.textSummary(text)) marked=\(textView.markedTextRange != nil) range=\(range.location):\(range.length)")
        return true
    }

    func textViewDidChange(_ textView: UITextView) {
        handleTextChange(
            currentText: textView.text ?? "",
            isComposing: textView.markedTextRange != nil
        )
    }
}
