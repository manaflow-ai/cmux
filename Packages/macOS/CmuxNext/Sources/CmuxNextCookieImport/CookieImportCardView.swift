public import AppKit
import CmuxNextDesign
import Observation

/// The cookie import permission card: one AppKit view the Home chat mounts inline above its
/// composer and the window card hosts, drawing ``CookieImportCardText`` for the ask's phase.
///
/// Asking, it reads top to bottom: the title, what will happen, who asked (a reference that
/// reveals that chat), the agent's reason boxed and labeled as its own words, the facts (from,
/// sites, into), the every-site warning in the warning color, what macOS asks next, and the
/// buttons: Deny (Escape) and Allow Once. Allow Once is never the default button, so Return
/// never allows, and it stays disabled for the arming beat. After the answer the same card
/// shows the Keychain step, then what came in with Remove, or why nothing did.
///
/// Motion: the card fades in through the overlays gate (no slide, so Reduce Motion changes
/// nothing but the fade's own policy), and the reading spinner (the shared one) stills under Reduce Motion.
@MainActor
public final class CookieImportCardView: NSView {
    /// The card's accessibility identifier (its buttons add `.allow`, `.deny`, and so on).
    public static let accessibilityID = "app.cookieImportConsent"

    /// The ask it draws.
    public let ask: CookieImportAsk
    /// The widest the card grows; it is narrower in a narrow chat.
    public static let maximumWidth: CGFloat = 520

    private let body = ThemeChangeView()
    private let stack = NSStackView()
    private var lastText: CookieImportCardText?
    private var watching = true
    private let spinner = StatusIndicatorView.spinner()

    /// - Parameter ask: The ask to draw; the view follows its phase until it is dismissed.
    public init(ask: CookieImportAsk) {
        self.ask = ask
        super.init(frame: .zero)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 12, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            stack.topAnchor.constraint(equalTo: body.topAnchor),
            stack.bottomAnchor.constraint(equalTo: body.bottomAnchor),
        ])
        let glass = Glass.makeOverlayPanel(content: body, cornerRadius: 14)
        glass.setAccessibilityIdentifier(Self.accessibilityID)
        glass.setAccessibilityElement(true)
        glass.setAccessibilityRole(.group)
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        spinner.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([spinner.widthAnchor.constraint(equalToConstant: 14), spinner.heightAnchor.constraint(equalToConstant: 14)])
        body.onThemeChange = { [weak self] in self?.render(force: true) }
        follow()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Stops following the ask (the host took the card down).
    public func stop() { watching = false }

    /// The card's height for `width` (hosts lay it out by hand above the composer).
    public func height(for width: CGFloat) -> CGFloat {
        frame.size.width = width
        layoutSubtreeIfNeeded()
        return ceil(fittingSize.height)
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        alphaValue = 0
        Motion.overlays.animate(.fadeIn, in: self, { animator().alphaValue = 1 })
        NSAccessibility.post(element: self, notification: .announcementRequested,
                             userInfo: [.announcement: lastText.map { $0.title + ". " + $0.lead } ?? "", .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    /// Escape answers Deny while asking (and closes a finished card).
    public override func cancelOperation(_ sender: Any?) {
        ask.dismiss()
    }

    private func follow() {
        guard watching else { return }
        withObservationTracking {
            render(force: false)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.follow() }
        }
    }

    private func render(force: Bool) {
        let text = CookieImportCardText(ask.request, phase: ask.phase, isArmed: ask.isArmed, showsSites: ask.showsSites,
                                        deadlineSeconds: Int(ask.limit.components.seconds))
        guard force || text != lastText else { return }
        let phaseChanged = lastText?.title != text.title
        lastText = text
        for view in stack.arrangedSubviews { stack.removeArrangedSubview(view); view.removeFromSuperview() }
        build(text)
        invalidateIntrinsicContentSize()
        superview?.needsLayout = true
        if phaseChanged, window != nil {
            NSAccessibility.post(element: self, notification: .announcementRequested, userInfo: [.announcement: text.title])
        }
    }

    private func build(_ text: CookieImportCardText) {
        let width = stack.widthAnchor
        func add(_ view: NSView, fill: Bool = true) {
            stack.addArrangedSubview(view)
            if fill { view.widthAnchor.constraint(equalTo: width, constant: -32).isActive = true }
        }
        let title = Self.label(text.title, size: TypeScale.title, weight: TypeScale.emphasis)
        title.textColor = performWithTheme { Palette.textPrimary }
        title.setAccessibilityRole(.staticText)
        if ask.phase == .reading {
            // The shared spinner stills itself under Reduce Motion.
            let row = NSStackView(views: [spinner, title])
            row.spacing = 8
            spinner.spin(true)
            add(row)
        } else {
            spinner.spin(false)
            add(title)
        }
        add(Self.label(text.lead, size: TypeScale.detail))
        if let requester = text.requester {
            let reference = NSButton(title: requester, target: self, action: #selector(showRequester))
            reference.isBordered = false
            reference.font = .systemFont(ofSize: TypeScale.detail, weight: TypeScale.emphasis)
            reference.contentTintColor = performWithTheme { Palette.accent }
            reference.isEnabled = ask.onShowRequester != nil
            reference.setAccessibilityIdentifier(Self.accessibilityID + ".requester")
            let row = NSStackView(views: [Self.caption(CookieImportStrings.requestedBy), reference])
            row.spacing = 6
            if let workspace = ask.request.requester.workspace, !workspace.isEmpty {
                row.addArrangedSubview(Self.label(CookieImportStrings.inWorkspace(workspace), size: TypeScale.detail, secondary: true))
            }
            add(row, fill: false)
        }
        if let reason = text.reason {
            add(Self.caption(CookieImportStrings.reasonLabel), fill: false)
            add(Self.boxed(Self.label(reason, size: TypeScale.field, weight: TypeScale.emphasis), id: "reason"))
        }
        if let latest = text.latest {
            add(Self.caption(CookieImportStrings.latestLabel), fill: false)
            add(Self.boxed(Self.label(latest, size: TypeScale.detail, secondary: true), id: "latest"))
        }
        if !text.rows.isEmpty {
            let grid = NSGridView(views: text.rows.map { [Self.caption($0.label), Self.label($0.value, size: TypeScale.detail)] })
            grid.rowSpacing = 4
            grid.columnSpacing = 10
            grid.column(at: 0).xPlacement = .trailing
            grid.setAccessibilityIdentifier(Self.accessibilityID + ".facts")
            add(grid)
        }
        if let warning = text.warning {
            let label = Self.label("⚠︎ " + warning, size: TypeScale.detail, weight: TypeScale.emphasis)
            label.textColor = .systemOrange
            label.setAccessibilityIdentifier(Self.accessibilityID + ".warning")
            add(label)
        }
        if let note = text.note {
            let label = Self.label(note, size: TypeScale.caption, secondary: true)
            label.setAccessibilityIdentifier(Self.accessibilityID + ".note")
            add(label)
        }
        guard !text.buttons.isEmpty else { return }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        var row: [NSView] = []
        for button in text.buttons {
            let view = makeButton(button)
            if button.role == .cancel || button.role == .primary, !row.contains(spacer) { row.append(spacer) }
            row.append(view)
        }
        let buttons = NSStackView(views: row)
        buttons.spacing = 8
        add(buttons)
    }

    private func makeButton(_ spec: CookieImportCardText.Button) -> NSButton {
        let button: NSButton
        switch spec.role {
        case .primary where spec.id == .allow:
            // Allow Once is a plain push button, never the default (Return does not press it).
            button = NSButton(title: spec.title, target: self, action: #selector(pressed(_:)))
            button.bezelColor = performWithTheme { Palette.accent }
        case .primary:
            // No Return key: inline, Return belongs to the chat's composer.
            button = NSButton(title: spec.title, target: self, action: #selector(pressed(_:)))
        case .cancel:
            let deny = ThemedBezelButton(title: spec.title, target: self, action: #selector(pressed(_:)))
            deny.keyHint = .escape
            button = deny
        case .normal:
            button = ThemedBezelButton(title: spec.title, target: self, action: #selector(pressed(_:)))
        }
        button.identifier = NSUserInterfaceItemIdentifier(spec.id.rawValue)
        button.isEnabled = spec.isEnabled
        button.setAccessibilityIdentifier(Self.accessibilityID + "." + spec.id.rawValue)
        if spec.id == .allow, !spec.isEnabled { button.toolTip = CookieImportStrings.allowOnce }
        return button
    }

    @objc private func pressed(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let action = CookieImportCardAction(rawValue: raw) else { return }
        perform(action)
    }

    /// Runs one of the card's buttons (the view's own clicks and an agent chat's tool card).
    func perform(_ action: CookieImportCardAction) {
        Self.perform(action, on: ask)
    }

    /// One button's effect on `ask`, shared by every host of the card.
    static func perform(_ action: CookieImportCardAction, on ask: CookieImportAsk) {
        switch action {
        case .allow: ask.answer(.allow)
        case .deny: ask.answer(.deny)
        case .showRequester: ask.onShowRequester?()
        case .remove: ask.remove()
        case .showAll: ask.onShowAll?()
        case .showSites: ask.showsSites = true
        case .dismiss: ask.dismiss()
        }
    }

    @objc private func showRequester() { ask.onShowRequester?() }

    private static func caption(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: TypeScale.caption, weight: TypeScale.emphasis)
        label.textColor = .secondaryLabelColor
        return label
    }

    private static func label(_ text: String, size: CGFloat, weight: NSFont.Weight = TypeScale.regular, secondary: Bool = false) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = secondary ? .secondaryLabelColor : .labelColor
        label.isSelectable = true
        label.focusRingType = .none
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        return label
    }

    private static func boxed(_ label: NSTextField, id: String) -> NSView {
        let box = NSBox()
        box.boxType = .custom
        box.cornerRadius = 8
        box.borderWidth = 1
        box.borderColor = .separatorColor
        box.fillColor = NSColor.textBackgroundColor.withAlphaComponent(0.35)
        box.contentViewMargins = NSSize(width: 10, height: 8)
        box.contentView = label
        box.setAccessibilityIdentifier(accessibilityID + "." + id)
        return box
    }
}
