import AppKit

/// One of a Keycap Playground cell's two sheets: a real dialog card (``CmuxDialogCardSurface``) in the light or
/// the dark theme, with Cancel (esc) and the default button (↩) drawing their keys in one ``CmuxDialogKeycapStyle``,
/// a row at rest, one hovered and one pressed (``CmuxDialogButtonView/previewState``).
@MainActor
final class CmuxKeycapPlaygroundSheet: NSView {
    let style: CmuxDialogKeycapStyle
    let isDark: Bool
    /// Each row's Cancel and default button, rest, hover then pressed.
    private(set) var buttons: [(cancel: CmuxDialogButtonView, confirm: CmuxDialogButtonView)] = []
    private let scope = ThemeScope(level: .room)

    init(style: CmuxDialogKeycapStyle, isDark: Bool, themes: CmuxToastPlaygroundThemes) {
        self.style = style
        self.isDark = isDark
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        // concentric-allow: the playground's stand-in page behind the card, not a container of the buttons.
        layer?.cornerRadius = Metrics.surfaceCornerRadius
        layer?.masksToBounds = true
        appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        if let theme = themes.theme(isDark: isDark) { scope.setOverride(theme.spec, input: theme.input, animated: false) }
        scope.root(self)
        setAccessibilityIdentifier("cmux.keycapPlayground.\(style.rawValue).\(isDark ? "dark" : "light")")
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") } // crash-allow: never decoded from a nib

    override var isFlipped: Bool { true }

    private func build() {
        let title = ThemedLabel(labelWithString: "Quit cmux?")
        title.font = Typography.bodyEmphasized
        title.themeColor = { Palette.textPrimary }
        let message = ThemedLabel(labelWithString: "2 agents are still working.")
        message.font = Typography.caption
        message.themeColor = { Palette.textSecondary }
        var views: [NSView] = [title, message]
        for state in CmuxDialogButtonLook.State.allCases {
            let cancel = button(CmuxDialogButton(id: "cancel", title: "Cancel", role: .cancel), hint: .escape, state: state)
            let confirm = button(CmuxDialogButton(id: "quit", title: "Quit", role: .default), hint: .return, state: state)
            buttons.append((cancel, confirm))
            let label = ThemedLabel(labelWithString: Self.name(of: state))
            label.font = Typography.caption
            label.themeColor = { Palette.textTertiary }
            let spacer = NSView()
            spacer.setContentHuggingPriority(.init(1), for: .horizontal)
            let row = NSStackView(views: [label, spacer, cancel, confirm])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 8
            views.append(row)
        }
        if style == .outside {
            let caption = ThemedLabel(labelWithString: "esc to cancel · ↩ to quit")
            caption.font = Typography.caption
            caption.themeColor = { Palette.textTertiary }
            views.append(caption)
        }
        let content = NSStackView(views: views)
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        content.setCustomSpacing(CmuxDialogMetrics.subtitleGap, after: title)
        let padding = CmuxDialogMetrics.cardPadding
        content.edgeInsets = NSEdgeInsets(top: padding, left: padding, bottom: padding, right: padding)
        content.translatesAutoresizingMaskIntoConstraints = false
        for row in views.compactMap({ $0 as? NSStackView }) {
            row.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -padding * 2).isActive = true
        }
        if let caption = views.last, style == .outside {
            // The caption sits under the buttons, at their trailing edge.
            caption.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -padding).isActive = true
        }
        let card = CmuxDialogCardSurface(content: content, activeLook: nil)
        // In a window of its own, not the overlay panel: the glass samples the page under it.
        card.glass.samplesBehindWindow = false
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            card.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            card.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            card.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
        ])
    }

    private func button(_ model: CmuxDialogButton, hint: CmuxDialogKeyHint, state: CmuxDialogButtonLook.State) -> CmuxDialogButtonView {
        let view = CmuxDialogButtonView(model, hint: hint, keycap: true, keycapStyle: style, target: self,
                                        action: #selector(pressSample(_:)))
        view.previewState = state == .rest ? nil : state
        view.identifier = NSUserInterfaceItemIdentifier("cmux.keycapPlayground.\(style.rawValue).\(model.id).\(state)")
        return view
    }

    /// The sample buttons answer a click with nothing: the rows show their looks.
    @objc private func pressSample(_ sender: Any?) {}

    private static func name(of state: CmuxDialogButtonLook.State) -> String {
        switch state {
        case .rest: "Rest"
        case .hover: "Hover"
        case .pressed: "Pressed"
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        paintGround()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paintGround()
    }

    private func paintGround() {
        // glass-opaque-allow: the stand-in for the window behind the dialog in the playground, not a glass surface.
        layer?.backgroundColor = performWithTheme { Palette.windowBackground.withAlphaComponent(1) }.cgColor
    }
}
