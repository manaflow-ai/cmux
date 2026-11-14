import AppKit

/// One of a playground row's two sheets: every sample kind drawn in one style, over a busy stand-in page,
/// in the light or the dark theme. The toasts are real ``CmuxToastView``s; ``replay()`` runs their real exit
/// and entrance (``CmuxToastMotion``).
@MainActor
final class CmuxToastPlaygroundSheet: NSView {
    let style: CmuxToastStyle
    let isDark: Bool
    private(set) var toasts: [CmuxToastView] = []
    private let scope = ThemeScope(level: .room)
    private let tuning: CmuxToastTuning

    init(style: CmuxToastStyle, isDark: Bool, themes: CmuxToastPlaygroundThemes, tuning: CmuxToastTuning) {
        self.style = style
        self.isDark = isDark
        self.tuning = tuning
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = Metrics.surfaceCornerRadius
        layer?.masksToBounds = true
        appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        if let theme = themes.theme(isDark: isDark) { scope.setOverride(theme.spec, input: theme.input, animated: false) }
        scope.root(self)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    private func build() {
        // A busy page under the glass, so each glass reads as it would over work.
        let page = ThemedLabel(wrappingLabelWithString: Self.pageText)
        page.font = Typography.system(.monospaced, size: 11)
        page.themeColor = { Palette.textTertiary }
        page.translatesAutoresizingMaskIntoConstraints = false
        addSubview(page)
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = style.look.placement == .bottomTrailing ? .trailing : .centerX
        stack.spacing = CmuxToastOverlayHost.stackGap + 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        for toast in CmuxToastPlaygroundSamples.kinds {
            let view = CmuxToastView(toast: toast, tuning: tuning, style: style)
            // In a window of its own, not the overlay panel: the glass samples the page under it.
            view.surface?.samplesBehindWindow = false
            view.setAccessibilityIdentifier("cmux.toastPlayground.\(style.rawValue).\(isDark ? "dark" : "light").\(toast.id)")
            toasts.append(view)
            stack.addArrangedSubview(view)
        }
        addSubview(stack)
        NSLayoutConstraint.activate([
            page.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            page.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            page.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 22),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -22),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            style.look.placement == .bottomTrailing
                ? stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16)
                : stack.centerXAnchor.constraint(equalTo: centerXAnchor),
        ])
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
        // glass-opaque-allow: the stand-in for the page behind the toasts in the playground, not a glass surface.
        layer?.backgroundColor = performWithTheme { Palette.windowBackground.withAlphaComponent(1) }.cgColor
    }

    /// Runs each toast's exit, then its entrance, a beat apart down the stack.
    func replay() {
        for view in toasts {
            CmuxToastMotion.disappear(view, animated: true) { [tuning] in
                CmuxToastMotion.appear(view, rise: tuning.rise)
            }
        }
    }

    /// Every toast's entrance, as when it first shows.
    func enter() {
        for view in toasts { CmuxToastMotion.appear(view, rise: tuning.rise) }
    }

    private static let pageText = (0..<14).map { line in
        ["~/work/cmux % git status", "On branch feat-cmux-next", "Changes not staged for commit:",
         "  modified:   Sources/CmuxNextDesign/Toast/CmuxToastView.swift", "~/work/cmux % swift build --product cmux",
         "[412/1180] Compiling CmuxNextDesign CmuxToastStyle.swift", "warning: unused variable 'look'"][line % 7]
    }.joined(separator: "\n")
}
