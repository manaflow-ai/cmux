public import AppKit

/// A text field on the theme's field fill (`Palette.chromeBackground`, a `Palette.separator`
/// hairline) instead of AppKit's bezel, which draws the system's colors whatever the room's
/// theme: dialog fields and Home's sheet and settings fields. While its field edits, the hairline
/// is the theme's focus ring (`Palette.focusRing`); a click anywhere in the box, padding included,
/// gives the field the keyboard. Callers set its width; it sets its own height.
/// Without chrome (`drawsChrome` false) it is the bare themed field, for a caller that draws its
/// own container (a row, a capsule search, a filled reply box).
public final class ThemedFieldBox: NSView {
    public let field: NSTextField
    /// The field fill and hairline; false leaves them to the caller's container.
    public let drawsChrome: Bool
    /// Called with true when the field takes the keyboard and false when its edit ends.
    public var onEditingChange: ((Bool) -> Void)?
    private var editing = false
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
        layer?.borderWidth = drawsChrome ? Metrics.dividerThickness : 0
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
        applyTheme()
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    private func applyTheme() {
        guard drawsChrome else { return }
        performWithTheme {
            layer?.backgroundColor = Palette.chromeBackground.cgColor
            layer?.borderColor = (editing ? Palette.focusRing : Palette.separator).cgColor
        }
    }
}
