import AppKit
import CmuxNextDesign

/// The first-run panel's "Switching" card: the core switching keys as the
/// live binding table has them (``HomeSwitchKeys``), a Hide button that
/// skips it for good, and, when Mission Control's Switch to Desktop takes
/// the tabs-by-number keys, a one-line note with a button to Keyboard
/// Shortcuts settings. Nothing here blocks: the card is information only.
final class HomeFirstRunSwitchCard: NSView {
    let header = ChromeLabel(labelWithString: HomeStrings.switchKeysHeader)
    let hide = NSButton(title: HomeStrings.switchKeysHide, target: nil, action: nil)
    let note = ChromeLabel(wrappingLabelWithString: HomeStrings.switchKeysDesktopConflict)
    let openSettings = NSButton(title: HomeStrings.switchKeysOpenSettings, target: nil, action: nil)
    private let surface = NSView()
    private(set) var lineViews: [(label: ChromeLabel, keys: ChromeLabel)] = []
    private(set) var keys: HomeSwitchKeys?
    private var scale: CGFloat = 1
    private var primary = NSColor.labelColor
    private var tertiary = NSColor.tertiaryLabelColor
    /// Hide: the host records it so the card never shows again.
    var onHide: () -> Void = {}
    /// The note's button: the host opens Keyboard Shortcuts settings.
    var onOpenSettings: () -> Void = {}

    static let lineHeight: CGFloat = 20
    static let inset: CGFloat = 12

    override init(frame: NSRect) {
        super.init(frame: frame)
        surface.wantsLayer = true
        surface.layer?.cornerRadius = HomeFirstRunRow.cornerRadius
        surface.layer?.cornerCurve = .continuous
        surface.layer?.borderWidth = 1
        addSubview(surface)
        header.isSelectable = false
        header.setAccessibilityRole(.staticText)
        note.isSelectable = false
        for button in [hide, openSettings] {
            button.isBordered = false
            button.target = self
            addSubview(button)
        }
        hide.action = #selector(hideClicked)
        openSettings.action = #selector(openSettingsClicked)
        for view in [header, note] as [NSView] { addSubview(view) }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(HomeStrings.switchKeysHeader)
        applyFonts()
        apply(nil)
    }

    required init?(coder: NSCoder) { nil }

    nonisolated override var isFlipped: Bool { true }

    @objc private func hideClicked() { onHide() }
    @objc private func openSettingsClicked() { onOpenSettings() }

    /// Shows `keys` (nil or no lines hides the card).
    func apply(_ keys: HomeSwitchKeys?) {
        self.keys = keys
        for line in lineViews { line.label.removeFromSuperview(); line.keys.removeFromSuperview() }
        lineViews = (keys?.lines ?? []).map { line in
            let label = ChromeLabel(labelWithString: line.label), caps = ChromeLabel(labelWithString: line.keys)
            for view in [label, caps] {
                view.isSelectable = false
                view.lineBreakMode = .byTruncatingTail
                addSubview(view)
            }
            caps.alignment = .right
            caps.setAccessibilityLabel(line.keys)
            return (label, caps)
        }
        let conflict = keys?.desktopConflict ?? false
        note.isHidden = !conflict
        openSettings.isHidden = !conflict
        isHidden = lineViews.isEmpty
        applyFonts()
        applyColors()
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    func applyScale(_ scale: CGFloat) {
        guard self.scale != scale else { return }
        self.scale = scale
        surface.layer?.cornerRadius = HomeFirstRunRow.cornerRadius * scale
        applyFonts()
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    /// Colours from the theme (caller runs inside `performWithTheme`).
    func applyColors(primary: NSColor, tertiary: NSColor, fill: NSColor, border: NSColor) { // theme-scoped
        self.primary = primary
        self.tertiary = tertiary
        surface.layer?.backgroundColor = fill.cgColor
        surface.layer?.borderColor = border.cgColor
        applyColors()
    }

    private func applyFonts() {
        header.font = .systemFont(ofSize: TypeScale.Base.detail * scale, weight: TypeScale.emphasis)
        note.font = .systemFont(ofSize: TypeScale.Base.caption * scale)
        for line in lineViews {
            line.label.font = .systemFont(ofSize: TypeScale.Base.detail * scale)
            line.keys.font = .systemFont(ofSize: TypeScale.Base.detail * scale)
        }
    }

    private func applyColors() {
        header.textColor = tertiary
        note.textColor = tertiary
        for line in lineViews {
            line.label.textColor = primary
            line.keys.textColor = tertiary
        }
        for button in [hide, openSettings] {
            button.attributedTitle = NSAttributedString(string: button.title, attributes: [
                .foregroundColor: button === hide ? tertiary : primary, .font: NSFont.systemFont(ofSize: TypeScale.Base.caption * scale),
            ])
        }
    }

    /// The card's height at `width`.
    func height(for width: CGFloat) -> CGFloat {
        guard !lineViews.isEmpty else { return 0 }
        let inset = Self.inset * scale
        var height = inset + Self.lineHeight * scale * CGFloat(1 + lineViews.count)
        if !note.isHidden {
            note.preferredMaxLayoutWidth = max(0, width - 2 * inset)
            height += 4 * scale + ceil(note.fittingSize.height) + Self.lineHeight * scale
        }
        return height + inset - 4 * scale
    }

    override func layout() {
        super.layout()
        surface.frame = bounds
        let inset = Self.inset * scale, line = Self.lineHeight * scale
        let inner = max(0, bounds.width - 2 * inset)
        func place(_ view: NSView, x: CGFloat, y: CGFloat, width: CGFloat) {
            let h = ceil(view.fittingSize.height)
            view.frame = CGRect(x: x, y: y + (line - h) / 2, width: width, height: h)
        }
        var y = inset - 4 * scale
        let hideWidth = ceil(hide.fittingSize.width)
        place(hide, x: bounds.width - inset - hideWidth, y: y, width: hideWidth)
        place(header, x: inset, y: y, width: max(0, inner - hideWidth - 8 * scale))
        y += line
        for row in lineViews {
            let capsWidth = min(inner / 2, ceil(row.keys.fittingSize.width) + 4)
            place(row.keys, x: bounds.width - inset - capsWidth, y: y, width: capsWidth)
            place(row.label, x: inset, y: y, width: max(0, inner - capsWidth - 8 * scale))
            y += line
        }
        if !note.isHidden {
            note.preferredMaxLayoutWidth = inner
            let h = ceil(note.fittingSize.height)
            note.frame = CGRect(x: inset, y: y + 4 * scale, width: inner, height: h)
            y += 4 * scale + h
            let buttonWidth = min(inner, ceil(openSettings.fittingSize.width))
            place(openSettings, x: inset, y: y, width: buttonWidth)
        }
    }
}
