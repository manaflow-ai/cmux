public import AppKit
import CmuxNextDesign

/// The permission card (gallery variant A, "Context card", Recommended):
/// who asks, the grant in plain words, the agent's reason, the person's
/// prompt, a gray warning row when they do not fit, and Deny ⎋ / Continue ↩.
/// After Continue it turns into the guide in place: the app tile to drag
/// into the list, or a line about the macOS prompt.
///
/// It draws a ``PendingPermissionRequest`` value and reports presses
/// through closures; it holds no reference to the request store.
public final class PermissionRequestCardView: NSView {
    /// The card's width (points).
    public static let width: CGFloat = 420

    /// Deny, Continue and Close presses.
    public struct Actions {
        public var deny: () -> Void
        public var proceed: () -> Void
        public var close: () -> Void

        public init(deny: @escaping () -> Void, proceed: @escaping () -> Void, close: @escaping () -> Void) {
            self.deny = deny
            self.proceed = proceed
            self.close = close
        }
    }

    private let strings = PermissionStrings()
    private let actions: Actions
    private let appURL: (PermissionKind) -> URL?
    private let appIcon: (PermissionKind) -> NSImage?
    private let stack = NSStackView()
    /// The card shows the guide (Esc closes it, Return does nothing).
    private var isGuiding = false

    /// - Parameters:
    ///   - actions: what the buttons do.
    ///   - appURL: the app that gets a grant (cmux, or the Computer Use helper), for the drag tile.
    ///   - appIcon: that app's icon, read off the main thread (nil until it is).
    public init(actions: Actions, appURL: @escaping (PermissionKind) -> URL?, appIcon: @escaping (PermissionKind) -> NSImage?) {
        self.actions = actions
        self.appURL = appURL
        self.appIcon = appIcon
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 10))
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(equalToConstant: Self.width),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") } // crash-allow: never decoded from a nib

    /// Draws `request` (nil: the short "Granted" confirm of `granted`).
    ///
    /// - Parameters:
    ///   - request: the request the card shows.
    ///   - waiting: how many more requests wait behind it.
    ///   - granted: the request that just ended granted, drawn when `request` is nil.
    public func render(_ request: PendingPermissionRequest?, waiting: Int, granted: PendingPermissionRequest? = nil) {
        for view in stack.arrangedSubviews { stack.removeArrangedSubview(view); view.removeFromSuperview() }
        isGuiding = request?.phase == .guiding
        guard let request else {
            if let granted {
                add(label(strings.title(granted.request.kind), size: TypeScale.title, weight: TypeScale.emphasis))
                add(label("✓ " + strings.granted, size: TypeScale.body, color: Palette.textSecondary))
            }
            return
        }
        let requester = request.request.requester
        var who = strings.agentLine(requester)
        if requester.isClaimed { who += " · " + strings.claimed }
        add(label(who, size: TypeScale.caption, weight: TypeScale.emphasis, color: Palette.textSecondary))
        add(label(strings.title(request.request.kind), size: TypeScale.title, weight: TypeScale.emphasis))
        add(label(strings.summary(request.request.kind), size: TypeScale.detail, color: Palette.textSecondary))
        switch request.phase {
        case .asking: renderAsking(request, waiting: waiting)
        case .guiding: renderGuiding(request)
        }
    }

    private func renderAsking(_ request: PendingPermissionRequest, waiting: Int) {
        add(section(strings.why, "“" + request.request.reason + "”"))
        if let prompt = request.request.prompt, !prompt.isEmpty {
            add(section(strings.youAsked, prompt))
        } else {
            add(label(strings.noPrompt, size: TypeScale.detail, color: Palette.textTertiary))
        }
        if request.reasonCheck == .unclear {
            add(label("⚠︎ " + strings.unclear, size: TypeScale.detail, weight: TypeScale.emphasis, color: Palette.textPrimary, lines: 3))
        }
        let deny = CmuxDialogButtonView(CmuxDialogButton(id: "deny", title: strings.deny, role: .cancel), hint: .escape,
                                        target: self, action: #selector(denyPressed))
        let proceed = CmuxDialogButtonView(CmuxDialogButton(id: "continue", title: strings.proceed, role: .default), hint: .return,
                                           target: self, action: #selector(continuePressed))
        var row: [NSView] = []
        if waiting > 0 { row.append(label(strings.more(waiting), size: TypeScale.caption, color: Palette.textTertiary)) }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        row += [spacer, deny, proceed]
        add(buttonRow(row))
    }

    private func renderGuiding(_ request: PendingPermissionRequest) {
        let grant = request.guidingGrant ?? request.request.kind.grants[0]
        if grant.usesDragHelper, let url = appURL(grant) {
            add(label(strings.dragGuide(PermissionAppTile.displayName(url)), size: TypeScale.detail, color: Palette.textPrimary, lines: 2))
            add(PermissionAppTile(appURL: url, icon: appIcon(grant)))
        } else {
            add(label(strings.promptGuide, size: TypeScale.detail, color: Palette.textPrimary, lines: 2))
        }
        let close = CmuxDialogButtonView(CmuxDialogButton(id: "close", title: strings.close, role: .cancel), hint: .escape,
                                         target: self, action: #selector(closePressed))
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        add(buttonRow([spacer, close]))
    }

    // MARK: Pieces

    private func add(_ view: NSView) {
        stack.addArrangedSubview(view)
        if view is NSStackView { view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true }
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = TypeScale.regular, color: NSColor = Palette.textPrimary,
                       lines: Int = 4) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.maximumNumberOfLines = lines
        field.lineBreakMode = .byTruncatingTail
        field.preferredMaxLayoutWidth = Self.width - 32
        return field
    }

    private func section(_ title: String, _ body: String) -> NSStackView {
        let column = NSStackView(views: [label(title, size: TypeScale.caption, weight: TypeScale.emphasis, color: Palette.textTertiary),
                                         label(body, size: TypeScale.body, lines: 3)])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 2
        return column
    }

    private func buttonRow(_ views: [NSView]) -> NSStackView {
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        return row
    }

    // MARK: Keys and presses

    @objc private func denyPressed() { actions.deny() }
    @objc private func continuePressed() { actions.proceed() }
    @objc private func closePressed() { actions.close() }

    /// Esc denies (or closes the guide); Return continues. Only once the
    /// person clicked into the card: the panel never takes the keyboard by itself.
    override public func cancelOperation(_ sender: Any?) {
        isGuiding ? actions.close() : actions.deny()
    }

    override public func keyDown(with event: NSEvent) {
        if !isGuiding, event.keyCode == 36 || event.keyCode == 76 { return actions.proceed() } // Return, keypad Enter
        super.keyDown(with: event)
    }

    override public var acceptsFirstResponder: Bool { true }
    override public func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
