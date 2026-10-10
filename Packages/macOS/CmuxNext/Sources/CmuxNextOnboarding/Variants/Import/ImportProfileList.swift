import AppKit
import CmuxNextBrowserImport
import CmuxNextDesign

/// The detected profiles as system checkboxes, in one of three shapes:
/// a plain stack, table rows (name left, checkbox right, hairlines), or one
/// row per browser with that browser's profiles beside it. While looking
/// or when nothing is found, a calm line takes the list's place.
final class ImportProfileList: NSView {
    enum Style { case checkboxes, rows, grouped }

    private let model: ImportStepModel
    private let style: Style
    private let font: NSFont
    private let stack = NSStackView()
    private lazy var scroll: NSScrollView = VariantLayout.scroller(stack)  // no IUO (crash program)
    private let empty: NSTextField
    private var boxes: [String: NSButton] = [:]
    private var shown: [BrowserSourceProfile]?
    private var loop: RenderLoop?

    init(model: ImportStepModel, style: Style, font: NSFont = OnboardingMetrics.bodyFont, spacing: CGFloat = 12,
         emptyAlignment: NSTextAlignment = .natural) {
        self.model = model
        self.style = style
        self.font = font
        empty = OnboardingLabel.make(font: OnboardingMetrics.bodyFont, color: Palette.textTertiary, lines: 2)
        empty.alignment = emptyAlignment
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = style == .checkboxes ? spacing : 0
        addSubview(scroll)
        addSubview(empty)
        let hug = bottomAnchor.constraint(equalTo: scroll.bottomAnchor)
        hug.priority = .init(470)
        // In row shapes the calm line sits where the first row's text would.
        let emptyInset: CGFloat = style == .checkboxes ? 0 : 12
        let hugEmpty = bottomAnchor.constraint(greaterThanOrEqualTo: empty.bottomAnchor, constant: emptyInset)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor), hug,
            stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            empty.leadingAnchor.constraint(equalTo: leadingAnchor), empty.trailingAnchor.constraint(equalTo: trailingAnchor),
            empty.topAnchor.constraint(equalTo: topAnchor, constant: emptyInset), hugEmpty,
        ])
        loop = RenderLoop { [weak self] in self?.render() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func toggled(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue, let profile = model.profiles.first(where: { $0.id == id }) else { return }
        model.toggle(profile)
    }

    private func render() {
        let profiles = model.profiles
        let emptyText = ImportKit.emptyText(model)
        empty.stringValue = emptyText ?? ""
        empty.isHidden = emptyText == nil
        scroll.isHidden = emptyText != nil
        if profiles != shown { rebuild(profiles) }
        let editable = model.canEditSelection
        for profile in profiles {
            boxes[profile.id]?.state = model.isSelected(profile) ? .on : .off
            boxes[profile.id]?.isEnabled = editable
        }
        for case let row as ImportCheckRow in stack.arrangedSubviews { row.syncEnabled() }
    }

    private func rebuild(_ profiles: [BrowserSourceProfile]) {
        shown = profiles
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        boxes = [:]
        switch style {
        case .checkboxes:
            for profile in profiles { stack.addArrangedSubview(box(profile, title: OnboardingStrings.profileName(profile))) }
        case .rows:
            for (index, profile) in profiles.enumerated() {
                let name = OnboardingStrings.profileName(profile)
                add(ImportCheckRow(title: name, font: font, box: box(profile, title: ""), separated: index < profiles.count - 1))
            }
        case .grouped:
            let groups = ImportKit.groups(profiles)
            for (index, group) in groups.enumerated() {
                let single = group.profiles.count == 1
                let checks = group.profiles.map { box($0, title: single ? "" : $0.displayName) }
                add(ImportBrowserRow(browser: group.browser.displayName, font: font, boxes: checks, separated: index < groups.count - 1))
            }
        }
    }

    private func add(_ row: NSView) {
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func box(_ profile: BrowserSourceProfile, title: String) -> NSButton {
        let box = OnboardingControl.checkbox(title, target: self, action: #selector(toggled(_:)))
        if !title.isEmpty { box.attributedTitle = NSAttributedString(string: title, attributes: [.font: font, .foregroundColor: Palette.textPrimary]) }
        box.identifier = NSUserInterfaceItemIdentifier(profile.id)
        box.setAccessibilityLabel(OnboardingStrings.profileName(profile))
        boxes[profile.id] = box
        return box
    }
}

/// One table row: the name on the left, a bare checkbox on the right, a
/// hairline under it. Clicking anywhere in the row toggles the box. The
/// shared hover fill covers the row (the list's clip view would cut off
/// anything past it); the name and box sit `inset` in from its edges.
final class ImportCheckRow: NSView {
    static let inset: CGFloat = 6
    private let box: NSButton
    private(set) lazy var hover = ChromeHover(self, tracking: .activeInKeyWindow)

    init(title: String, font: NSFont, box: NSButton, separated: Bool) {
        self.box = box
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let label = OnboardingLabel.make(title, font: font)
        let line = VariantLayout.hairline()
        line.isHidden = !separated
        line.translatesAutoresizingMaskIntoConstraints = false
        for view in [label, box, line] { addSubview(view) }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 40),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset), label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: box.leadingAnchor, constant: -12),
            box.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.inset), box.centerYAnchor.constraint(equalTo: centerYAnchor),
            line.leadingAnchor.constraint(equalTo: leadingAnchor), line.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Call after the box's `isEnabled` changes: a row that locks under the
    /// pointer drops its hover and press.
    func syncEnabled() {
        guard !box.isEnabled else { return }
        hover.state.hovering = false
        hover.state.pressed = false
    }

    override func layout() {
        super.layout()
        hover.layout()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        hover.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { if box.isEnabled { hover.state.hovering = true } }
    override func mouseExited(with event: NSEvent) { hover.state.hovering = false }

    override func mouseDown(with event: NSEvent) {
        guard box.isEnabled else { return }
        hover.state.pressed = true
    }

    /// Toggles on release inside the row, as a button does.
    override func mouseUp(with event: NSEvent) {
        guard hover.state.pressed else { return }
        hover.state.pressed = false
        if box.isEnabled, bounds.contains(convert(event.locationInWindow, from: nil)) { box.performClick(nil) }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        hover.refresh(animated: false)
    }
}

/// One browser per row: its name on the left, a checkbox per profile on
/// the right (a bare box when the browser has one profile).
final class ImportBrowserRow: NSView {
    init(browser: String, font: NSFont, boxes: [NSButton], separated: Bool) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let label = OnboardingLabel.make(browser, font: .systemFont(ofSize: font.pointSize, weight: .medium))
        let checks = NSStackView(views: boxes)
        checks.spacing = 16
        checks.translatesAutoresizingMaskIntoConstraints = false
        let line = VariantLayout.hairline()
        line.isHidden = !separated
        line.translatesAutoresizingMaskIntoConstraints = false
        for view in [label, checks, line] { addSubview(view) }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 44),
            label.leadingAnchor.constraint(equalTo: leadingAnchor), label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: checks.leadingAnchor, constant: -16),
            checks.trailingAnchor.constraint(equalTo: trailingAnchor), checks.centerYAnchor.constraint(equalTo: centerYAnchor),
            line.leadingAnchor.constraint(equalTo: leadingAnchor), line.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        label.setContentCompressionResistancePriority(.init(740), for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
