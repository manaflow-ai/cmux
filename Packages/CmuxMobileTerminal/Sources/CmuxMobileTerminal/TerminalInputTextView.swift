import CmuxMobileTerminalKit
import Foundation
import UIKit

final class TerminalInputTextView: UITextView {
    var onText: ((String) -> Void)?
    var onBackspace: (() -> Void)?
    var onEscapeSequence: ((Data) -> Void)?
    /// Invoked when the Paste accessory button reads an image off the system
    /// clipboard. The host forwards the bytes (+ a lowercase format hint) to the
    /// Mac, which injects the resulting file path into the terminal. Clipboard
    /// *text* does not use this path; it rides ``onText``.
    var onPasteImage: ((Data, String) -> Void)?
    var onZoom: ((TerminalFontZoomDirection) -> Void)?
    var onHideKeyboard: (() -> Void)?
    /// Fired by the trailing "customize" button so the SwiftUI host can present
    /// the toolbar shortcuts editor.
    var onOpenToolbarSettings: (() -> Void)?
    var accessoryLayoutInsetsProvider: (() -> UIEdgeInsets)?
    /// The leftmost toolbar button. Toggles its glyph between dismiss-keyboard
    /// (when the keyboard is up) and show-keyboard (when down) via
    /// ``setKeyboardShown(_:)``.
    private weak var dismissButton: UIButton?
    /// The armed/sticky modifier state machine, extracted into the testable
    /// ``TerminalInputModifierState`` reducer. This view is now a dumb
    /// first-responder that forwards taps into the reducer and reads its state
    /// back for byte encoding and button styling.
    private var modifierState = TerminalInputModifierState()
    private var controlAccessoryArmed: Bool { modifierState.isArmed(.control) }
    private var alternateAccessoryArmed: Bool { modifierState.isArmed(.alternate) }
    private var commandAccessoryArmed: Bool { modifierState.isArmed(.command) }
    private var shiftAccessoryArmed: Bool { modifierState.isArmed(.shift) }
    private var controlAccessorySticky: Bool { modifierState.isStickyOn(.control) }
    private var alternateAccessorySticky: Bool { modifierState.isStickyOn(.alternate) }
    private var commandAccessorySticky: Bool { modifierState.isStickyOn(.command) }
    private var shiftAccessorySticky: Bool { modifierState.isStickyOn(.shift) }
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
        .control, .alternate, .command, .paste,
    ]

    /// The structural buttons pinned to the end of the bar, after the
    /// user-configurable shortcuts. The zoom controls live here so the
    /// high-traffic shortcuts sit directly after the modifier keys.
    private static let pinnedTrailingActions: [TerminalInputAccessoryAction] = [
        .zoomOut, .zoomIn,
    ]

    /// Build (or rebuild) the bar's buttons: the pinned modifier controls, the
    /// user-configurable shortcuts in their saved order, then the pinned zoom
    /// controls. Safe to call repeatedly; it clears the stack first.
    private func populateAccessoryActions() {
        guard let stack = accessoryStackView else { return }
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        commandAccessoryButton?.removeFromSuperview()
        commandAccessoryButton = nil

        // Pinned leading modifier controls, in fixed order.
        for action in Self.pinnedLeadingActions {
            let button = makeAccessoryButton(for: action)
            // Command is Mac-only; kept out of the stack and inserted by
            // applyModifierPresentation() when driving a Mac remote.
            if action == .command {
                commandAccessoryButton = button
            } else {
                stack.addArrangedSubview(button)
            }
        }
        // The user-configurable region: built-in shortcuts and custom actions in
        // the user's saved order.
        for item in TerminalAccessoryConfiguration.shared.enabledItems {
            switch item {
            case let .builtin(action):
                stack.addArrangedSubview(makeAccessoryButton(for: action))
            case let .custom(custom):
                stack.addArrangedSubview(makeCustomAccessoryButton(for: custom))
            }
        }
        // Pinned trailing zoom controls, after the configurable shortcuts (the
        // redesigned bar moved zoom here from the leading region).
        for action in Self.pinnedTrailingActions {
            stack.addArrangedSubview(makeAccessoryButton(for: action))
        }
        // The "customize" button pinned at the very end of the bar.
        stack.addArrangedSubview(makeToolbarSettingsButton())
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
        for case let button as AccessoryActionButton in stack.arrangedSubviews {
            guard case let .builtin(action) = button.item else { continue }
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
                        if let button = view as? AccessoryActionButton,
                           case .builtin(.alternate) = button.item {
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
        if !isMacRemote && commandAccessoryArmed {
            modifierState.disarmAll()
            refreshAccessoryButtonStyles()
        }
    }

    init() {
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
        if commandAccessoryArmed, markedTextRange == nil, !hasText {
            if !commandAccessorySticky {
                setCommandAccessoryArmed(false)
            }
            // Cmd+Backspace on Mac = delete to start of line (Ctrl+U / 0x15)
            onEscapeSequence?(Data([0x15]))
            return
        }
        if alternateAccessoryArmed, markedTextRange == nil, !hasText {
            if !alternateAccessorySticky {
                setAlternateAccessoryArmed(false)
            }
            if let output = TerminalHardwareKeyResolver.data(
                input: UIKeyCommand.inputDelete,
                modifierFlags: [.alternate]
            ) {
                onEscapeSequence?(output)
            }
            return
        }
        if controlAccessoryArmed, markedTextRange == nil, !hasText {
            if !controlAccessorySticky {
                setControlAccessoryArmed(false)
            }
            onBackspace?()
            return
        }
        if markedTextRange != nil || hasText {
            super.deleteBackward()
            return
        }
        onBackspace?()
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
        modifierState.clearDoubleTapWindow()
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
        guard let button = sender as? AccessoryActionButton else { return }
        switch button.item {
        case let .builtin(action):
            handleAccessoryAction(action)
        case let .custom(custom):
            handleCustomAction(custom)
        }
    }

    @objc
    private func handleOpenToolbarSettings() {
        onOpenToolbarSettings?()
    }

    /// Fire a custom action's bytes. Custom actions are macros, so any armed
    /// modifier is cleared first to avoid silently modifying the macro's output.
    private func handleCustomAction(_ custom: CustomToolbarAction) {
        disarmAllModifiers()
        refreshAccessoryButtonStyles()
        guard let output = custom.output else { return }
        onEscapeSequence?(output)
    }

    @discardableResult
    private func handleHardwareKeyInput(input: String, modifierFlags: UIKeyModifierFlags) -> Bool {
        guard let data = TerminalHardwareKeyResolver.data(input: input, modifierFlags: modifierFlags) else {
            return false
        }
        onEscapeSequence?(data)
        return true
    }

    private func makeAccessoryButton(for action: TerminalInputAccessoryAction) -> AccessoryActionButton {
        let button = AccessoryActionButton(item: .builtin(action))
        button.translatesAutoresizingMaskIntoConstraints = false
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

    private func makeCustomAccessoryButton(for custom: CustomToolbarAction) -> AccessoryActionButton {
        let button = AccessoryActionButton(item: .custom(custom))
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(handleAccessoryButton(_:)), for: .touchUpInside)
        button.accessibilityIdentifier = "terminal.inputAccessory.custom.\(custom.id.uuidString)"
        button.accessibilityLabel = custom.title
        button.titleLabel?.font = Self.accessoryButtonFont

        if let symbolName = custom.symbolName,
           !symbolName.isEmpty,
           UIImage(systemName: symbolName) != nil {
            button.setImage(UIImage(systemName: symbolName), for: .normal)
            button.setPreferredSymbolConfiguration(Self.accessoryButtonSymbolConfig, forImageIn: .normal)
            button.accessibilityLabel = custom.title
        } else {
            button.setTitle(custom.title, for: .normal)
        }

        applyAccessoryButtonBaseStyle(button)
        return button
    }

    /// The trailing button that opens the toolbar shortcuts editor. A plain
    /// `UIButton` (not an ``AccessoryActionButton``) so the armed-modifier
    /// styling/relabel loops skip it, and styled to read as a control rather
    /// than an insertable key.
    private func makeToolbarSettingsButton() -> UIButton {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(handleOpenToolbarSettings), for: .touchUpInside)
        button.accessibilityIdentifier = "terminal.inputAccessory.customize"
        button.accessibilityLabel = String(
            localized: "terminal.input_accessory.customize",
            defaultValue: "Customize Toolbar"
        )
        button.setImage(UIImage(systemName: "slider.horizontal.3"), for: .normal)
        button.setPreferredSymbolConfiguration(Self.accessoryButtonSymbolConfig, forImageIn: .normal)
        applyAccessoryButtonBaseStyle(button)
        button.backgroundColor = .clear
        button.tintColor = UIColor(white: 0.7, alpha: 1)
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
        if action == .paste {
            // Paste is a clipboard read, not a key sequence: ignore any armed
            // modifier and route clipboard content to the host directly.
            disarmAllModifiers()
            refreshAccessoryButtonStyles()
            handlePasteAction()
            return
        }

        if let zoomDirection = action.zoomDirection {
            disarmAllModifiers()
            refreshAccessoryButtonStyles()
            onZoom?(zoomDirection)
            return
        }

        if controlAccessoryArmed,
           !action.isModifier {
            if !controlAccessorySticky {
                setControlAccessoryArmed(false)
            }
            if let output = action.output {
                onEscapeSequence?(output)
            }
            return
        }

        if alternateAccessoryArmed,
           !action.isModifier {
            if !alternateAccessorySticky {
                setAlternateAccessoryArmed(false)
            }
            if let output = alternateAccessoryOutput(for: action) {
                onEscapeSequence?(output)
            }
            return
        }

        if commandAccessoryArmed,
           !action.isModifier {
            if !commandAccessorySticky {
                setCommandAccessoryArmed(false)
            }
            if let output = commandAccessoryOutput(for: action) {
                onEscapeSequence?(output)
            }
            return
        }

        switch action {
        case .control:
            toggleControlModifier()
        case .alternate:
            toggleAlternateModifier()
        case .command:
            toggleCommandModifier()
        case .shift:
            toggleShiftModifier()
        default:
            if let output = action.output {
                onEscapeSequence?(output)
            }
        }
    }

    /// Read the system clipboard for the Paste button. An image is forwarded via
    /// ``onPasteImage`` (the host uploads it to the Mac as `terminal.paste_image`
    /// and the Mac injects the resulting file path); plain text rides the normal
    /// ``onText`` input path. Images win when both are present. A large image
    /// falls back to JPEG so it stays under the Mac's 10 MB cap. Accessing the
    /// pasteboard contents here is what shows iOS's one-shot paste banner, which
    /// is the expected confirmation for an explicit Paste tap.
    private func handlePasteAction() {
        let pasteboard = UIPasteboard.general
        if pasteboard.hasImages, let image = pasteboard.image {
            let maxImageBytes = 8 * 1024 * 1024
            if let png = image.pngData(), png.count <= maxImageBytes {
                onPasteImage?(png, "png")
                return
            }
            if let jpeg = image.jpegData(compressionQuality: 0.8) {
                onPasteImage?(jpeg, "jpg")
                return
            }
            if let png = image.pngData() {
                onPasteImage?(png, "png")
                return
            }
        }
        if pasteboard.hasStrings, let string = pasteboard.string, !string.isEmpty {
            onText?(string)
        }
    }

    private func disarmAllModifiers() {
        modifierState.disarmAll()
    }

    private func toggleControlModifier() {
        modifierState.tap(.control, now: Self.tapNow())
        refreshAccessoryButtonStyles()
    }

    private func toggleAlternateModifier() {
        modifierState.tap(.alternate, now: Self.tapNow())
        refreshAccessoryButtonStyles()
    }

    private func toggleCommandModifier() {
        modifierState.tap(.command, now: Self.tapNow())
        refreshAccessoryButtonStyles()
    }

    private func toggleShiftModifier() {
        modifierState.tap(.shift, now: Self.tapNow())
        refreshAccessoryButtonStyles()
    }

    private func refreshAccessoryButtonStyles() {
        guard let stack = accessoryStackView else { return }
        for case let button as AccessoryActionButton in stack.arrangedSubviews {
            // Only built-in modifier keys arm; custom actions always render normal.
            let armed: Bool
            let sticky: Bool
            if case let .builtin(action) = button.item {
                armed = isAccessoryActionArmed(action)
                sticky = isAccessoryActionSticky(action)
            } else {
                armed = false
                sticky = false
            }
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
        if controlAccessoryArmed {
            if !controlAccessorySticky {
                setControlAccessoryArmed(false)
            }
            if let controlSequence = controlSequence(for: committedText) {
                onEscapeSequence?(controlSequence)
            } else {
                onText?(committedText)
            }
        } else if alternateAccessoryArmed {
            if !alternateAccessorySticky {
                setAlternateAccessoryArmed(false)
            }
            if let alternateSequence = alternateSequence(for: committedText) {
                onEscapeSequence?(alternateSequence)
            } else {
                onText?(committedText)
            }
        } else if commandAccessoryArmed {
            if !commandAccessorySticky {
                setCommandAccessoryArmed(false)
            }
            if let commandSequence = commandTextSequence(for: committedText) {
                onEscapeSequence?(commandSequence)
            } else {
                onText?(committedText)
            }
        } else if shiftAccessoryArmed {
            if !shiftAccessorySticky {
                setShiftAccessoryArmed(false)
            }
            onText?(committedText.uppercased())
        } else {
            onText?(committedText)
        }
    }

    /// Translate Cmd+<letter> typed through the soft keyboard into Mac-terminal
    /// readline shortcuts (cmd+a = start of line, cmd+e = end, cmd+k = kill line, etc).
    private func commandTextSequence(for text: String) -> Data? {
        guard text.count == 1, let char = text.lowercased().first else { return nil }
        switch char {
        case "a": return Data([0x01]) // Ctrl+A - beginning of line
        case "e": return Data([0x05]) // Ctrl+E - end of line
        case "k": return Data([0x0B]) // Ctrl+K - kill to end of line
        case "u": return Data([0x15]) // Ctrl+U - kill to start of line
        case "w": return Data([0x17]) // Ctrl+W - delete previous word
        case "l": return Data([0x0C]) // Ctrl+L - clear screen
        case "c": return Data([0x03]) // Ctrl+C - SIGINT
        case "d": return Data([0x04]) // Ctrl+D - EOF
        default: return nil
        }
    }

    private func controlSequence(for text: String) -> Data? {
        guard text.count == 1 else { return nil }
        return TerminalHardwareKeyResolver.data(input: text, modifierFlags: [.control])
    }

    private func alternateSequence(for text: String) -> Data? {
        guard let encoded = text.data(using: .utf8), !encoded.isEmpty else { return nil }
        var sequence = Data([0x1B])
        sequence.append(encoded)
        return sequence
    }

    private func alternateAccessoryOutput(for action: TerminalInputAccessoryAction) -> Data? {
        switch action {
        case .leftArrow:
            return TerminalHardwareKeyResolver.data(
                input: UIKeyCommand.inputLeftArrow,
                modifierFlags: [.alternate]
            )
        case .rightArrow:
            return TerminalHardwareKeyResolver.data(
                input: UIKeyCommand.inputRightArrow,
                modifierFlags: [.alternate]
            )
        case .control, .alternate, .command:
            return nil
        default:
            guard let output = action.output else { return nil }
            var sequence = Data([0x1B])
            sequence.append(output)
            return sequence
        }
    }

    /// Translate Cmd+<key> into the equivalent Mac-terminal readline sequence.
    /// Cmd+Left/Right = start/end of line (Ctrl+A / Ctrl+E).
    /// Cmd+Backspace is handled directly in deleteBackward() as Ctrl+U.
    private func commandAccessoryOutput(for action: TerminalInputAccessoryAction) -> Data? {
        switch action {
        case .leftArrow:
            return Data([0x01]) // Ctrl+A - beginning of line
        case .rightArrow:
            return Data([0x05]) // Ctrl+E - end of line
        case .upArrow:
            // Cmd+Up on Mac often scrolls; just send the raw arrow
            return TerminalHardwareKeyResolver.data(
                input: UIKeyCommand.inputUpArrow,
                modifierFlags: []
            )
        case .downArrow:
            return TerminalHardwareKeyResolver.data(
                input: UIKeyCommand.inputDownArrow,
                modifierFlags: []
            )
        case .control, .alternate, .command, .shift:
            return nil
        default:
            return action.output
        }
    }

    private func isAccessoryActionArmed(_ action: TerminalInputAccessoryAction) -> Bool {
        switch action {
        case .control: return controlAccessoryArmed
        case .alternate: return alternateAccessoryArmed
        case .command: return commandAccessoryArmed
        case .shift: return shiftAccessoryArmed
        default: return false
        }
    }

    private func isAccessoryActionSticky(_ action: TerminalInputAccessoryAction) -> Bool {
        switch action {
        case .control: return controlAccessorySticky
        case .alternate: return alternateAccessorySticky
        case .command: return commandAccessorySticky
        case .shift: return shiftAccessorySticky
        default: return false
        }
    }

    /// Consumes a one-shot modifier after it applied to a key. Only `false`
    /// (disarm) is ever requested; a sticky lock is preserved by the reducer.
    private func consumeModifier(_ modifier: TerminalInputModifier) {
        modifierState.consumeIfNotSticky(modifier)
        refreshAccessoryButtonStyles()
    }

    private func setCommandAccessoryArmed(_ armed: Bool) {
        if !armed { consumeModifier(.command) }
    }

    private func setControlAccessoryArmed(_ armed: Bool) {
        if !armed { consumeModifier(.control) }
    }

    private func setAlternateAccessoryArmed(_ armed: Bool) {
        if !armed { consumeModifier(.alternate) }
    }

    private func setShiftAccessoryArmed(_ armed: Bool) {
        if !armed { consumeModifier(.shift) }
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
