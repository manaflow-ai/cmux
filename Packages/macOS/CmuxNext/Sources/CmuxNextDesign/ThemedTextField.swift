public import AppKit

/// A text field for short-lived editors (inline renames, dialog fields) that keeps its colors in
/// its theme scope while it is open: a theme change repaints the scope and calls
/// `viewDidChangeEffectiveAppearance`, which re-applies the field's colors and those of its
/// active field editor (text, caret, selection). Its placeholder is the scope's hint ink, never
/// macOS's gray. It draws no focus ring: it sits inside a styled container whose own state shows
/// focus, and AppKit's ring is a system-blue square around the field (cx-ncc.57).
public final class ThemedTextField: NSTextField, ThemedTextInput {
    /// The fill behind the text, resolved in the field's scope.
    public var fill: @MainActor () -> NSColor = { Palette.windowBackground }
    /// The text's ink, resolved in the field's scope: an inline rename takes the ink of the label it
    /// edits in place, so the text keeps its color as editing starts.
    public var ink: @MainActor () -> NSColor = { Palette.textPrimary }
    private var placeholderText: String?
    /// AppKit's own placeholder bookkeeping while the themed one is set is not the caller's.
    private var applyingColors = false
    /// Called with true when the field takes the keyboard and false when its edit ends, for a
    /// container that shows focus (`ThemedFieldBox`).
    public var onEditingChange: ((Bool) -> Void)?

    /// The placeholder carries its own font: it follows the field's.
    public override var font: NSFont? {
        didSet { applyThemeColors() }
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        focusRingType = .none
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        focusRingType = .none
    }

    /// Drawn in the scope's hint ink (`Palette.textTertiary`).
    public override var placeholderString: String? {
        get { placeholderText }
        set {
            guard !applyingColors else { return }
            placeholderText = newValue
            applyThemeColors()
        }
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyThemeColors()
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyThemeColors()
    }

    public override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        applyThemeColors()
        if became { onEditingChange?(true) }
        return became
    }

    public override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        // Return on a field with an action can select the text again inside `super` (editing goes
        // on): report the state after it, not a bare false.
        onEditingChange?(currentEditor() != nil)
    }

    public func applyThemeColors() {
        guard !applyingColors else { return }
        applyingColors = true
        defer { applyingColors = false }
        performWithTheme { applyThemedFieldColors(fill: fill(), placeholder: placeholderText, ink: ink()) }
    }
}

/// `ThemedTextField`'s colors on a secure field (a dialog's password or token): its characters
/// never reach the screen or the pasteboard.
public final class ThemedSecureTextField: NSSecureTextField, ThemedTextInput {
    /// The fill behind the text, resolved in the field's scope.
    public var fill: @MainActor () -> NSColor = { Palette.windowBackground }
    private var placeholderText: String?
    /// AppKit's own placeholder bookkeeping while the themed one is set is not the caller's.
    private var applyingColors = false
    /// Called with true when the field takes the keyboard and false when its edit ends, for a
    /// container that shows focus (`ThemedFieldBox`).
    public var onEditingChange: ((Bool) -> Void)?

    /// The placeholder carries its own font: it follows the field's.
    public override var font: NSFont? {
        didSet { applyThemeColors() }
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        focusRingType = .none
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        focusRingType = .none
    }

    /// Drawn in the scope's hint ink (`Palette.textTertiary`).
    public override var placeholderString: String? {
        get { placeholderText }
        set {
            guard !applyingColors else { return }
            placeholderText = newValue
            applyThemeColors()
        }
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyThemeColors()
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyThemeColors()
    }

    public override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        applyThemeColors()
        if became { onEditingChange?(true) }
        return became
    }

    public override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        // Return on a field with an action can select the text again inside `super` (editing goes
        // on): report the state after it, not a bare false.
        onEditingChange?(currentEditor() != nil)
    }

    public func applyThemeColors() {
        guard !applyingColors else { return }
        applyingColors = true
        defer { applyingColors = false }
        performWithTheme { applyThemedFieldColors(fill: fill(), placeholder: placeholderText) }
    }
}

/// A themed field (`ThemedTextField`, `ThemedSecureTextField`) that reports when it edits.
@MainActor
public protocol ThemedTextInput: NSTextField {
    var onEditingChange: ((Bool) -> Void)? { get set }
}

extension NSTextField {
    /// Sets `placeholder` as the field's placeholder in the active scope's hint ink
    /// (`Palette.textTertiary`) and the field's font, for a stock field whose host re-applies its
    /// colors on a theme change; nil removes it. theme-scoped
    public func applyThemedPlaceholder(_ placeholder: String?) {
        guard let placeholder, !placeholder.isEmpty else {
            setPlaceholderKeepingEdit(nil)
            return
        }
        setPlaceholderKeepingEdit(NSAttributedString(string: placeholder, attributes: [
            .foregroundColor: Palette.textTertiary,
            .font: font ?? Typography.body,
        ]))
    }

    /// The field's setter ends and restarts an active edit, which runs the end-editing and focus
    /// paths mid-typing; the cell's only redraws.
    public func setPlaceholderKeepingEdit(_ placeholder: NSAttributedString?) {
        // This cell draws its own placeholder, on the editor's line; AppKit's would sit above it.
        if let aligned = cell as? EditorAlignedTextFieldCell {
            aligned.drawnPlaceholder = placeholder
            return
        }
        guard currentEditor() != nil, let cell = cell as? NSTextFieldCell else {
            placeholderAttributedString = placeholder
            return
        }
        cell.placeholderAttributedString = placeholder
        needsDisplay = true
    }

    /// Text, placeholder, fill and the active field editor's caret and selection in the active
    /// scope. theme-scoped
    func applyThemedFieldColors(fill: NSColor, placeholder: String?, ink: NSColor = Palette.textPrimary) {
        backgroundColor = fill
        textColor = ink
        applyThemedPlaceholder(placeholder)
        guard let editor = currentEditor() as? NSTextView else { return }
        editor.textColor = ink
        editor.insertionPointColor = Palette.caret
        editor.selectedTextAttributes = [.backgroundColor: Palette.textSelection]
    }
}
