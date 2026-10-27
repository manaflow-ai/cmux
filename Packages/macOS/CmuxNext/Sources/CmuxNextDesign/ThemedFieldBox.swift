public import AppKit
public import CmuxNextAppearance

/// A text field on the theme's field fill (`Palette.chromeBackground`, a `Palette.separator`
/// hairline) instead of AppKit's bezel, which draws the system's colors whatever the room's
/// theme: dialog fields and Home's sheet and settings fields. While its field edits, the border is
/// the theme's focus ring (`Palette.focusRing`) at 1.5 pt (2 pt under Increase Contrast), on the
/// box's rounded corners: the Tab cue of a form with several fields, never AppKit's square blue
/// ring (cx-ncc.88). It shows under `appearance.borders` none too. A click anywhere in the box,
/// padding included, gives the field the keyboard. Callers set its width; it sets its own height.
/// Without chrome (`drawsChrome` false) it is the bare themed field, for a caller that draws its
/// own container (a row, a capsule search, a filled reply box).
public final class ThemedFieldBox: NSView {
    public let field: NSTextField
    /// The field fill and hairline; false leaves them to the caller's container.
    public let drawsChrome: Bool
    /// Called with true when the field takes the keyboard and false when its edit ends.
    public var onEditingChange: ((Bool) -> Void)?
    private var editing = false
    /// Increase Contrast changes the focus border's width; the setting is not observable otherwise.
    private var contrastWatch: AppearanceSignals.Subscription?
    private var heightConstraint: NSLayoutConstraint?

    /// The box's height; a change (a live density change) resizes it.
    public var height: CGFloat {
        get { heightConstraint?.constant ?? 0 }
        set { if heightConstraint?.constant != newValue { heightConstraint?.constant = newValue } }
    }

    public init(field: NSTextField, height: CGFloat, drawsChrome: Bool = true) {
        self.field = field
        self.drawsChrome = drawsChrome
        super.init(frame: .zero)
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = Metrics.itemCornerRadius
        layer?.cornerCurve = .continuous
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        (field as? any ThemedTextInput)?.onEditingChange = { [weak self] editing in
            guard let self else { return }
            self.editing = editing
            applyTheme()
            onEditingChange?(editing)
        }
        let heightConstraint = heightAnchor.constraint(equalToConstant: height)
        self.heightConstraint = heightConstraint
        NSLayoutConstraint.activate([
            heightConstraint,
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: drawsChrome ? Metrics.space2 : 0),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: drawsChrome ? -Metrics.space2 : 0),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        applyTheme()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") } // crash-allow: never decoded from a nib

    /// A click in the padding focuses the field, as a click on a bezeled field's edge does. While
    /// the field is already editing it keeps its edit (no restart, no select-all).
    public override func mouseDown(with event: NSEvent) {
        guard field.isEditable, field.isEnabled, let window else { return super.mouseDown(with: event) }
        guard field.currentEditor() == nil else { return }
        window.makeFirstResponder(field)
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        contrastWatch = nil
        if window != nil {
            contrastWatch = DesignSettings.shared.signals.subscribe([.displayOptions], owner: "ThemedFieldBox") { [weak self] in
                self?.applyTheme()
            }
        }
        applyTheme()
    }

    // visibility-walk-allow: three layer stores (fill, border color, border width); no layout, cheaper than a deferral
    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    /// The focus border's width: wider under Increase Contrast. Not `Metrics.lineWidth`: the focus
    /// cue stays when `appearance.borders` hides decorative lines.
    private var focusBorderWidth: CGFloat {
        NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 2 : 1.5
    }

    private func applyTheme() {
        guard drawsChrome else { return }
        performWithTheme {
            layer?.backgroundColor = Palette.chromeBackground.cgColor
            layer?.borderColor = (editing ? Palette.focusRing : Palette.separator).cgColor
            layer?.borderWidth = editing ? focusBorderWidth : Metrics.dividerThickness
        }
    }
}
