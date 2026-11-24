import AppKit

/// One style in the Toast Playground: its number, name and one line on what it is; Fire it (the style as
/// real toasts in the window), Replay (its exit and entrance again) and Pick (the style of every toast from
/// now on); then its light and dark sheets.
@MainActor
final class CmuxToastPlaygroundRow: NSView {
    let style: CmuxToastStyle
    let sheets: [CmuxToastPlaygroundSheet]
    private let pickButton = NSButton(title: "", target: nil, action: nil)
    private let onFire: (CmuxToastStyle) -> Void
    private let onPick: (CmuxToastStyle) -> Void

    init(style: CmuxToastStyle, number: Int, themes: CmuxToastPlaygroundThemes, tuning: CmuxToastTuning,
         onFire: @escaping (CmuxToastStyle) -> Void, onPick: @escaping (CmuxToastStyle) -> Void) {
        self.style = style
        self.onFire = onFire
        self.onPick = onPick
        sheets = [false, true].map { CmuxToastPlaygroundSheet(style: style, isDark: $0, themes: themes, tuning: tuning) }
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        build(number: number)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func build(number: Int) {
        let title = ThemedLabel(labelWithString: "\(number). \(style.title)")
        title.font = Typography.system(size: TypeScale.title, weight: TypeScale.emphasis)
        title.themeColor = { Palette.textPrimary }
        let summary = ThemedLabel(wrappingLabelWithString: style.summary)
        summary.font = Typography.body
        summary.themeColor = { Palette.textSecondary }
        let text = NSStackView(views: [title, summary])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        let fire = NSButton(title: "Fire it", target: self, action: #selector(fire))
        fire.setAccessibilityIdentifier("cmux.toastPlayground.\(style.rawValue).fire")
        let replay = NSButton(title: "Replay", target: self, action: #selector(replay))
        replay.setAccessibilityIdentifier("cmux.toastPlayground.\(style.rawValue).replay")
        pickButton.target = self
        pickButton.action = #selector(pick)
        pickButton.setAccessibilityIdentifier("cmux.toastPlayground.\(style.rawValue).pick")
        for button in [fire, replay, pickButton] { button.bezelStyle = .push }
        let header = NSStackView(views: [text, NSView(), fire, replay, pickButton])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        header.setHuggingPriority(.defaultLow, for: .horizontal)
        let pair = NSStackView(views: sheets)
        pair.orientation = .horizontal
        pair.distribution = .fillEqually
        pair.alignment = .top
        pair.spacing = 12
        let column = NSStackView(views: [header, pair])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 10
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            header.widthAnchor.constraint(equalTo: column.widthAnchor),
            pair.widthAnchor.constraint(equalTo: column.widthAnchor),
        ])
    }

    /// Shows whether this style is the one picked.
    func showPicked(_ picked: CmuxToastStyle) {
        let isPicked = picked == style
        pickButton.title = isPicked ? "✓ Picked" : "Pick"
        pickButton.isEnabled = !isPicked
        pickButton.keyEquivalent = ""
    }

    @objc private func fire() { onFire(style) }
    @objc private func replay() { sheets.forEach { $0.replay() } }
    @objc private func pick() { onPick(style) }
}
