import AppKit

/// Swift live mode's quiet mark in the window's top row, after the toolbar band (and the badge and
/// host pressure indicator while they show): "Live mode" in secondary caption text on the subtle
/// hover gray, no glyph, no motion. It shows while this app is the live code build
/// (`cmux live start --swift`, docs/cmux-next/live-code.md), which is slower and bigger than the
/// normal build; its tooltip says so and how to go back. A press on it never moves the window.
public final class LiveModeBadgeView: NSView, TitlebarPressDeciding {
    private let label = ChromeLabel(labelWithString: LiveModeBadgeView.title)

    public static var title: String {
        String(localized: "liveMode.badge", defaultValue: "Live mode", bundle: .module)
    }

    public static var help: String {
        String(localized: "liveMode.badgeHelp",
               defaultValue: "Swift live mode: this is the live code build of this commit, slower and bigger than the normal build, and the Swift you patch in applies at once. Stop Swift Live Mode restarts into the normal build with every session.",
               bundle: .module)
    }

    override public init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        label.font = Typography.caption
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.space2),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.space2),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
        themedToolTip = Self.help
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(Self.help)
        setAccessibilityIdentifier("window.liveMode.badge")
        applyColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public func titlebarPress(atWindowPoint windowPoint: CGPoint) -> TitlebarPress { .staysPut }

    override public func layout() {
        super.layout()
        layer?.cornerRadius = Metrics.chipCornerRadius(height: bounds.height)
    }

    override public func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    /// Theme tokens only: secondary text on the hover gray, as the incognito badge.
    private func applyColors() {
        performWithTheme {
            label.textColor = Palette.textSecondary
            layer?.backgroundColor = Palette.hoverFill.cgColor
        }
    }

    override public func hitTest(_ point: NSPoint) -> NSView? { nil }
}
