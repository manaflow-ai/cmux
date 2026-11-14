import AppKit

/// The Toast Playground's content: what is picked now, then one row per style (``CmuxToastStyle``), each
/// with every kind of toast in light and dark. Picking one makes it the style of every toast and prompt the
/// app draws, at once and after a relaunch (``CmuxToastCenter/pick(_:)``).
@MainActor
final class CmuxToastPlaygroundView: NSView, CmuxToastStyleFollowing {
    private let center: CmuxToastCenter
    private(set) var rows: [CmuxToastPlaygroundRow] = []
    private let pickedLabel = ThemedLabel(labelWithString: "")
    let scrollView = NSScrollView()

    /// - Parameters:
    ///   - center: The toasts' center: its pick, and where Fire it shows toasts.
    ///   - themes: The light and dark sheets' themes.
    ///   - fire: Shows `style`'s toasts as real toasts (in the window the person works in).
    ///   - focus: Which styles show (Debug Settings > Toasts > Playground shows).
    init(center: CmuxToastCenter, themes: CmuxToastPlaygroundThemes, focus: CmuxToastPlaygroundFocus = .all,
         fire: @escaping (CmuxToastStyle) -> Void) {
        self.center = center
        super.init(frame: .zero)
        let tuning = center.tuning
        rows = focus.styles.map { style in
            CmuxToastPlaygroundRow(style: style, number: (CmuxToastStyle.allCases.firstIndex(of: style) ?? 0) + 1, themes: themes, tuning: tuning, onFire: fire) { [weak center] in
                center?.pick($0)
            }
        }
        build()
        center.styles.follow(self)
        toastStyleDidChange(center.style)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func build() {
        pickedLabel.font = Typography.system(size: TypeScale.body, weight: TypeScale.emphasis)
        pickedLabel.themeColor = { Palette.textPrimary }
        let intro = ThemedLabel(wrappingLabelWithString:
            "Every kind of toast in each style, light and dark. Fire it shows the style as real toasts in your window; "
            + "Pick makes it the style of every toast and prompt in the app, now and after a relaunch.")
        intro.font = Typography.body
        intro.themeColor = { Palette.textSecondary }
        let column = NSStackView(views: [pickedLabel, intro] + rows)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 28
        column.setCustomSpacing(4, after: pickedLabel)
        column.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 28, right: 24)
        column.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedPlaygroundDocument()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(column)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.documentView = document
        addSubview(scrollView)
        var constraints = [
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            document.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            column.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            column.topAnchor.constraint(equalTo: document.topAnchor),
            column.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            intro.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -48),
        ]
        constraints += rows.map { $0.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -48) }
        NSLayoutConstraint.activate(constraints)
    }

    func toastStyleDidChange(_ style: CmuxToastStyle) {
        pickedLabel.stringValue = "Picked: \(style.title)"
        rows.forEach { $0.showPicked(style) }
    }

    /// Every sheet's toasts enter, as when they first show.
    func enter() {
        rows.flatMap(\.sheets).forEach { $0.enter() }
    }
}

/// The playground's document: rows from the top.
private final class FlippedPlaygroundDocument: NSView {
    nonisolated override var isFlipped: Bool { true }
}
