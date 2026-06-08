import CmuxMobileTerminalKit
import Foundation
import UIKit

/// The iOS terminal's keyboard input surface.
///
/// This is a **documentless responder**, not a text editor. It conforms to
/// ``UIKeyInput`` and ``UITextInput`` directly on a bare `UIView` (the same
/// construction iSH's `TerminalView` ships) instead of subclassing
/// `UITextView`. Every committed character is forwarded to the remote Mac and
/// nothing is echoed locally, so there is no editable buffer to keep in sync —
/// the view owns only a transient IME ``markedText`` string.
///
/// ## Why not a `UITextView`
///
/// A `UITextView` (or any real-document field) drives backspace auto-repeat and
/// dictation off its internal text storage and selection, not off
/// ``UIKeyInput/hasText``. The previous implementation forced `hasText` to
/// `true` but cleared its document to `""` after every keystroke, so:
///
/// - **hold-to-repeat backspace** stopped after one delete: with an empty
///   document and a collapsed selection at offset 0 the framework had nothing to
///   repeat-delete, and a `UITextView` never consults the overridden `hasText`
///   for repeat.
/// - **system dictation** never landed: dictation inserts a placeholder into the
///   document then replaces it with the recognized text, but the per-keystroke
///   `text = ""` clear nuked the placeholder mid-flight.
///
/// A bare ``UIKeyInput``/``UITextInput`` responder with no document has neither
/// problem. The framework honors ``hasText`` for repeat on a raw responder, and
/// the explicit dictation-placeholder methods on a real (non-cleared)
/// `UITextInput` conformer let recognized text arrive through ``insertText(_:)``
/// as one multi-character block, which routes to the bracketed-paste sink.
///
/// Autocorrect/predictive text stay **disabled** here and fundamentally cannot
/// be enabled: they require the field to retain the in-progress word, which is
/// incompatible with forwarding every keystroke to a remote terminal.
final class TerminalInputTextView: UIView, UIKeyInput, UITextInput {
    var onText: ((String) -> Void)?
    var onBackspace: (() -> Void)?
    var onEscapeSequence: ((Data) -> Void)?
    /// Invoked for a committed *block* of text (more than one character) that no
    /// modifier transforms: system dictation, autocorrect/predictive-bar
    /// replacements, and clipboard text inserted by the keyboard all arrive this
    /// way. The host routes the block through a bracketed-paste RPC so the remote
    /// terminal receives it as a single paste rather than per-character input,
    /// which avoids CR-fragmenting multi-line text and lets TUIs treat it as
    /// pasted content. Single characters and Return still ride ``onText``.
    var onPasteText: ((String) -> Void)?
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

    /// The in-progress IME composition string, or `nil` when not composing.
    ///
    /// This is the view's *only* text state. While an IME (CJK, emoji-via-IME)
    /// is composing, UIKit calls ``setMarkedText(_:selectedRange:)`` with the
    /// candidate; the view holds it here so ``markedTextRange`` reports active
    /// composition and ``text(in:)`` can answer the framework's read-back. On
    /// ``unmarkText()`` the held string commits through ``insertText(_:)`` and
    /// this clears. There is no committed-document buffer.
    private var markedText: String?

    /// Monotonic-ish tap timestamp for the reducer's double-tap window. Uses
    /// the same wall-clock source the legacy `Date()` comparisons used, so the
    /// 0.4s sticky promotion behaves identically.
    private static func tapNow() -> TimeInterval { Date().timeIntervalSinceReferenceDate }

    /// Long-lived sentinel identifying the IME marked-text region. Returned from
    /// ``markedTextRange`` only while ``markedText`` is non-nil; UIKit compares
    /// it by object identity.
    private let markedTextRangeSentinel = TerminalInputTextRange()
    /// Long-lived sentinel identifying the (always empty) selection. Returned
    /// from ``selectedTextRange``; its presence is what stops the "speak
    /// selection" action from crashing while looking for a selection.
    private let selectedTextRangeSentinel = TerminalInputTextRange()

    /// The framework-supplied delegate that wants to know about marked/selection
    /// changes. Required stored property of the ``UITextInput`` conformance; the
    /// view notifies it around ``setMarkedText(_:selectedRange:)`` so the IME
    /// candidate UI stays in sync.
    weak var inputDelegate: (any UITextInputDelegate)?

    /// Word/sentence tokenizer required by ``UITextInput``. The view has no
    /// document to tokenize, but the protocol mandates a non-nil tokenizer; the
    /// default string tokenizer satisfies it without ever being meaningfully
    /// queried.
    lazy var tokenizer: any UITextInputTokenizer = UITextInputStringTokenizer(textInput: self)

    override var canBecomeFirstResponder: Bool { true }

    /// Conforming to ``UITextInput`` would otherwise make this an accessibility
    /// element, which would shadow the real terminal surface's accessibility
    /// content. The view is an invisible input proxy, so keep it out of the
    /// accessibility tree (the surface carries the rendered-text label). iSH does
    /// the same for the same reason.
    override var isAccessibilityElement: Bool {
        get { false }
        set {}
    }

    /// Always report that there is text to delete.
    ///
    /// This is the load-bearing piece (borrowed from iSH's `TerminalView`) that
    /// makes the system software keyboard's *hold-to-repeat* backspace work. On
    /// a bare ``UIKeyInput`` responder (this view) the keyboard's auto-repeat
    /// timer keeps firing ``deleteBackward()`` only while the first responder
    /// reports `hasText == true`; the moment it reads `false` the repeat stops.
    /// It is always safe to send a DEL byte to the remote terminal, so there is
    /// no "nothing to delete" state to honor — return `true` unconditionally and
    /// let the keyboard repeat indefinitely.
    ///
    /// Internal byte-routing therefore must *not* key off `hasText` (it is a
    /// constant); ``deleteBackward()`` and the modifier guards key off
    /// ``markedText`` (IME composition) instead.
    var hasText: Bool { true }

    override var keyCommands: [UIKeyCommand]? {
        guard markedText == nil else { return nil }
        var commands = TerminalHardwareKeyResolver.makeKeyCommands(
            target: self,
            action: #selector(handleHardwareKeyCommand(_:))
        )
        // A bare UIView does not inherit UITextView's Cmd+V, so wire it
        // explicitly to the same clipboard routing as the toolbar Paste button.
        commands.append(UIKeyCommand(input: "v", modifierFlags: [.command], action: #selector(paste(_:))))
        return commands
    }

    /// Restores standard system paste on this documentless responder.
    ///
    /// As a `UITextView` the view inherited `paste(_:)`/`canPerformAction(_:)`;
    /// as a bare `UIView` it must re-expose them so hardware Cmd+V and the
    /// edit-menu Paste keep working. Only paste is advertised — copy/cut/select
    /// are meaningless on a proxy that holds no document, so they stay disabled
    /// rather than surfacing a broken edit menu.
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)) {
            return UIPasteboard.general.hasStrings || UIPasteboard.general.hasImages
        }
        return false
    }

    /// System Paste (Cmd+V or the edit-menu item) routed through the same
    /// clipboard handling as the toolbar Paste button: an image goes to the Mac
    /// as `terminal.paste_image`, text rides the bracketed-paste sink.
    override func paste(_ sender: Any?) {
        handlePasteAction()
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
        super.init(frame: .zero)
        backgroundColor = .clear
        tintColor = .clear
        // The view owns no visible content; it is a zero-size hidden responder
        // docked by `GhosttySurfaceView`. The accessory bar is no longer the
        // keyboard's `inputAccessoryView`; `GhosttySurfaceView` docks
        // `toolbarView` persistently at the bottom so it survives keyboard
        // dismissal. Leaving `inputAccessoryView` nil means the keyboard shows
        // without its own accessory (the docked bar rides above it via
        // `keyboardLayoutGuide`).
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

    /// Receive a committed character (or block) from the keyboard.
    ///
    /// This is the single sink for every soft-keyboard text insertion: typed
    /// characters, an emoji-picker tap, an IME-committed candidate, and the
    /// recognized text of a dictation session (delivered as one multi-character
    /// block). It never edits a local document — it routes straight to the
    /// remote terminal. Committing here also ends any IME composition.
    func insertText(_ text: String) {
        guard !text.isEmpty else { return }
        TerminalInputDebugLog.log("proxy.insertText text=\(TerminalInputDebugLog.textSummary(text)) composing=\(markedText != nil)")
        // A committed insert ends composition. The candidate the IME was showing
        // is exactly `text`, so clear the marked state and emit `text` once.
        if markedText != nil {
            withMarkedTextChange { markedText = nil }
        }
        emitCommittedText(text, source: "insertText")
    }

    func deleteBackward() {
        // Routing keys off `markedText` (IME composition in progress), NOT
        // `hasText`: `hasText` is a forced constant `true` so the software
        // keyboard auto-repeats backspace, so it can no longer mean "the local
        // document is empty". While composing, the delete edits the marked text
        // locally; otherwise it is a real backspace that must reach the Mac.
        if commandAccessoryArmed, markedText == nil {
            if !commandAccessorySticky {
                setCommandAccessoryArmed(false)
            }
            // Cmd+Backspace on Mac = delete to start of line (Ctrl+U / 0x15)
            onEscapeSequence?(Data([0x15]))
            return
        }
        if alternateAccessoryArmed, markedText == nil {
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
        if controlAccessoryArmed, markedText == nil {
            if !controlAccessorySticky {
                setControlAccessoryArmed(false)
            }
            onBackspace?()
            return
        }
        // While composing (marked text present), cancel the composition rather
        // than self-editing the marked string. The IME owns decomposition and
        // drives it through `setMarkedText` (the candidate shown is the IME's own
        // floating bar; this view is invisible, so `markedText` is just a mirror
        // of what the IME last pushed). A documentless view cannot decompose a
        // syllable itself, and modeling it as a Swift `Character` drop would nuke
        // a whole CJK syllable (한 is one `Character`) while pretending to step
        // back. Canceling is honest and emits nothing to the Mac; an IME that
        // routes composition-backspace through here gets a clean reset.
        if markedText != nil {
            // Distinguishes the rarely-hit `deleteBackward`-drives-composition
            // path from the common IME-driven `setMarkedText` path during device
            // dogfood (gated on CMUX_INPUT_DEBUG; not a temporary probe).
            TerminalInputDebugLog.log("deleteBackward.composing cancel marked composition")
            setMarkedText(nil, selectedRange: NSRange(location: 0, length: 0))
            return
        }
        onBackspace?()
    }

    // MARK: Dictation
    //
    // This view is a bare `UIView` conforming to `UITextInput` (the same
    // construction as iSH's `TerminalView`), so it must supply the dictation
    // placeholder hooks itself — see ``insertDictationResultPlaceholder()`` and
    // ``removeDictationResultPlaceholder(_:willInsertResult:)`` in the
    // `UITextInput` conformance below. When the user taps the keyboard mic,
    // UIKit asks for a placeholder, runs recognition, then delivers the
    // recognized text through ``insertText(_:)`` as one multi-character block,
    // which ``emitCommittedText(_:source:)`` routes to the bracketed-paste sink
    // (``onPasteText``). Because the view keeps no document, nothing can clear
    // the placeholder mid-flight, which is what broke dictation on the prior
    // `UITextView` design.

    /// Test seam standing in for an IME/dictation/commit cycle.
    ///
    /// Drives the same path the keyboard would: composing text marks, then a
    /// non-composing change commits it. Mirrors the real
    /// ``setMarkedText(_:selectedRange:)`` → ``insertText(_:)`` flow so tests can
    /// assert routing (single char vs. paste block) without a live keyboard.
    func simulateTextChangeForTesting(_ text: String, isComposing: Bool) {
        if isComposing {
            setMarkedText(text, selectedRange: NSRange(location: text.count, length: 0))
        } else {
            markedText = nil
            guard !text.isEmpty else { return }
            emitCommittedText(text, source: "textChange")
        }
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
    /// and the Mac injects the resulting file path); plain text rides the
    /// bracketed-paste ``onPasteText`` path so multi-line clipboard text lands as
    /// one paste instead of executing line-by-line. Images win when both are
    /// present. A large image falls back to JPEG so it stays under the Mac's
    /// 10 MB cap. Accessing the pasteboard contents here is what shows iOS's
    /// one-shot paste banner, which is the expected confirmation for an explicit
    /// Paste tap.
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
            // An explicit Paste is always pasted content, so it goes through the
            // bracketed-paste sink (which falls back to per-key input on a host
            // that does not support it). The host gates the fallback on the
            // `terminal.paste.v1` capability.
            if onPasteText != nil {
                onPasteText?(string)
            } else {
                onText?(string)
            }
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
            emitUnmodifiedText(committedText.uppercased())
        } else {
            emitUnmodifiedText(committedText)
        }
    }

    /// Route a committed block with no active modifier to either the per-key
    /// input path or the bracketed-paste path.
    ///
    /// Single characters and Return keep riding ``onText`` so byte semantics
    /// (CR for Return, control bytes, the existing per-keystroke flow) are
    /// unchanged. A multi-character block — system dictation, an
    /// autocorrect/predictive replacement, or keyboard-inserted clipboard text —
    /// is sent through ``onPasteText`` so it reaches the remote terminal as one
    /// bracketed paste instead of fragmenting on embedded newlines.
    private func emitUnmodifiedText(_ text: String) {
        switch TerminalCommitRouter.route(for: text) {
        case .paste where onPasteText != nil:
            onPasteText?(text)
        case .paste, .input:
            // No paste sink wired (or a single character): per-character input.
            onText?(text)
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

// MARK: - UITextInputTraits

extension TerminalInputTextView {
    // Autocorrect/predictive/smart substitutions are all off: the view forwards
    // each keystroke to the remote terminal and keeps no in-progress word for
    // the keyboard to correct against. Returning these as computed properties
    // (rather than the `UITextView` stored traits the old design used) keeps the
    // keyboard from offering corrections it could never apply.
    var autocorrectionType: UITextAutocorrectionType { get { .no } set {} }
    var autocapitalizationType: UITextAutocapitalizationType { get { .none } set {} }
    var spellCheckingType: UITextSpellCheckingType { get { .no } set {} }
    var smartQuotesType: UITextSmartQuotesType { get { .no } set {} }
    var smartDashesType: UITextSmartDashesType { get { .no } set {} }
    var smartInsertDeleteType: UITextSmartInsertDeleteType { get { .no } set {} }
    var keyboardType: UIKeyboardType { get { .default } set {} }
    var returnKeyType: UIReturnKeyType { get { .default } set {} }
}

// MARK: - UITextInput (documentless conformance)

// This view owns no editable document. It implements `UITextInput` to unlock two
// keyboard features that a bare `UIKeyInput` view does not get — system
// dictation (the mic key) and IME marked-text composition — exactly the way
// iSH's `TerminalView` does. Recognized dictation text and committed IME
// candidates both arrive through ``insertText(_:)`` and route to the terminal;
// the geometry/offset methods return neutral values because there is nothing to
// measure. UIKit compares the marked/selected ranges by object identity.
extension TerminalInputTextView {
    var markedTextRange: UITextRange? { markedText != nil ? markedTextRangeSentinel : nil }

    var selectedTextRange: UITextRange? {
        get { selectedTextRangeSentinel }
        set {}
    }

    var markedTextStyle: [NSAttributedString.Key: Any]? {
        get { nil }
        set {}
    }

    var beginningOfDocument: UITextPosition { TerminalInputTextPosition() }
    var endOfDocument: UITextPosition { TerminalInputTextPosition() }

    /// The IME hands a candidate string in; hold it as the marked composition so
    /// ``markedTextRange`` reports active composition. Nothing is sent to the
    /// terminal until the candidate commits via ``insertText(_:)`` (driven by
    /// the keyboard) or ``unmarkText()``.
    ///
    /// Mutating ``markedText`` changes the string the view exposes through
    /// ``text(in:)``/``markedTextRange``, so it is a *text* change in the
    /// ``UITextInputDelegate`` contract: it is bracketed with
    /// `textWillChange`/`textDidChange` (via ``withMarkedTextChange(_:)``) so the
    /// IME and dictation machinery keep their composition state synchronized.
    func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        TerminalInputDebugLog.log("proxy.setMarkedText text=\(TerminalInputDebugLog.textSummary(markedText ?? "")) ")
        withMarkedTextChange {
            self.markedText = (markedText?.isEmpty == true) ? nil : markedText
        }
    }

    /// Brackets a mutation of ``markedText`` with the `UITextInputDelegate`
    /// text-change callbacks.
    ///
    /// The marked composition is the only text this view exposes, so any change
    /// to it (set by the IME, committed by ``insertText(_:)``/``unmarkText()``,
    /// or canceled by ``replace(_:withText:)``) is a text change UIKit must be
    /// told about with `textWillChange`/`textDidChange`. Selection-only callbacks
    /// would leave the keyboard observing stale composition state.
    private func withMarkedTextChange(_ mutate: () -> Void) {
        inputDelegate?.textWillChange(self)
        mutate()
        inputDelegate?.textDidChange(self)
    }

    /// Commit the in-progress IME composition. Forwards the held candidate to the
    /// terminal as one block (multi-character commits route to bracketed paste).
    func unmarkText() {
        guard let composing = markedText else { return }
        withMarkedTextChange { markedText = nil }
        emitCommittedText(composing, source: "unmarkText")
    }

    func text(in range: UITextRange) -> String? {
        if range === markedTextRangeSentinel { return markedText }
        if range === selectedTextRangeSentinel { return "" }
        return nil
    }

    /// Commit text delivered through a range replacement.
    ///
    /// Most committed input arrives via ``insertText(_:)``, but some system
    /// paths (text replacement, certain dictation/suggestion commits) deliver it
    /// by replacing ``selectedTextRange`` or ``markedTextRange`` instead. The
    /// view holds no addressable document, so the range itself is ignored, but
    /// the *text* must still reach the terminal — route it through the same
    /// commit path as ``insertText(_:)`` rather than dropping it. A replacement
    /// of the marked region also supersedes the in-progress IME composition, so
    /// clear it first. An empty replacement is a pure deletion of the marked
    /// composition (no committed text to send).
    func replace(_ range: UITextRange, withText text: String) {
        TerminalInputDebugLog.log("proxy.replace text=\(TerminalInputDebugLog.textSummary(text)) marked=\(range === markedTextRangeSentinel)")
        if range === markedTextRangeSentinel, markedText != nil {
            withMarkedTextChange { markedText = nil }
        }
        guard !text.isEmpty else { return }
        emitCommittedText(text, source: "replace")
    }
    func textRange(from fromPosition: UITextPosition, to toPosition: UITextPosition) -> UITextRange? { nil }
    func position(from position: UITextPosition, offset: Int) -> UITextPosition? { nil }
    func position(from position: UITextPosition, in direction: UITextLayoutDirection, offset: Int) -> UITextPosition? { nil }
    func compare(_ position: UITextPosition, to other: UITextPosition) -> ComparisonResult { .orderedSame }
    func offset(from: UITextPosition, to toPosition: UITextPosition) -> Int { 0 }
    func position(within range: UITextRange, farthestIn direction: UITextLayoutDirection) -> UITextPosition? { nil }
    func characterRange(byExtending position: UITextPosition, in direction: UITextLayoutDirection) -> UITextRange? { nil }
    func baseWritingDirection(for position: UITextPosition, in direction: UITextStorageDirection) -> NSWritingDirection { .leftToRight }
    func setBaseWritingDirection(_ writingDirection: NSWritingDirection, for range: UITextRange) {}
    func firstRect(for range: UITextRange) -> CGRect { .zero }
    func caretRect(for position: UITextPosition) -> CGRect { .zero }
    func selectionRects(for range: UITextRange) -> [UITextSelectionRect] { [] }
    func closestPosition(to point: CGPoint) -> UITextPosition? { nil }
    func closestPosition(to point: CGPoint, within range: UITextRange) -> UITextPosition? { nil }
    func characterRange(at point: CGPoint) -> UITextRange? { nil }

    // MARK: Dictation placeholder hooks
    //
    // UIKit calls these when the mic is tapped. Returning a placeholder (an
    // empty token; iSH does the same) is what tells the framework this view
    // accepts dictation; the recognized text then arrives via `insertText`. The
    // remove hook is a no-op because there is no document placeholder to strip.
    func insertDictationResultPlaceholder() -> Any { "" }
    func removeDictationResultPlaceholder(_ placeholder: Any, willInsertResult: Bool) {}
}
