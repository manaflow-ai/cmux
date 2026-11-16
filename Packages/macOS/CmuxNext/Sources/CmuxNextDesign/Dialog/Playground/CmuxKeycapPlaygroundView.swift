import AppKit

/// The Keycap Playground's content: a Light and Dark switch, then a grid, four styles across, each style's sheet
/// (``CmuxKeycapPlaygroundSheet``) in the theme the switch picks, in one scrolling column.
@MainActor
final class CmuxKeycapPlaygroundView: NSView {
    /// One sheet per style, in ``CmuxDialogKeycapStyle/allCases`` order, all light or all dark.
    private(set) var sheets: [CmuxKeycapPlaygroundSheet] = []
    let isDark: Bool
    let scrollView = OverlayScrollView()
    private let modes = NSSegmentedControl(labels: ["Light", "Dark"], trackingMode: .selectOne, target: nil, action: nil)
    private let onMode: (Bool) -> Void
    static let columns = 4

    /// - Parameters:
    ///   - themes: The light and dark sheets' themes.
    ///   - isDark: Draws every sheet in the dark theme, else the light one.
    ///   - onMode: The switch moved: show the grid in the dark theme (`true`) or the light one.
    init(themes: CmuxToastPlaygroundThemes, isDark: Bool, onMode: @escaping (Bool) -> Void = { _ in }) {
        self.isDark = isDark
        self.onMode = onMode
        super.init(frame: .zero)
        let cells = CmuxDialogKeycapStyle.allCases.map { style -> NSView in
            let sheet = CmuxKeycapPlaygroundSheet(style: style, isDark: isDark, themes: themes)
            sheets.append(sheet)
            return Self.cell(style, sheet)
        }
        build(cells)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") } // crash-allow: never decoded from a nib

    private static func cell(_ style: CmuxDialogKeycapStyle, _ sheet: NSView) -> NSView {
        let title = ThemedLabel(labelWithString: style.title)
        title.font = Typography.system(size: TypeScale.body, weight: TypeScale.emphasis)
        title.themeColor = { Palette.textPrimary }
        let note = ThemedLabel(wrappingLabelWithString: style.note)
        note.font = Typography.caption
        note.themeColor = { Palette.textSecondary }
        let stack = NSStackView(views: [title, note, sheet])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(2, after: title)
        stack.setAccessibilityIdentifier("cmux.keycapPlayground.\(style.rawValue)")
        NSLayoutConstraint.activate([
            note.widthAnchor.constraint(equalTo: stack.widthAnchor),
            sheet.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        return stack
    }

    private func build(_ cells: [NSView]) {
        let intro = ThemedLabel(wrappingLabelWithString:
            "Each style on a real dialog card's real buttons: Cancel (esc) and the default button (↩), at rest, hovered "
            + "and pressed. Every dialog draws style 2; the others are here to compare.")
        intro.font = Typography.body
        intro.themeColor = { Palette.textSecondary }
        let rows = stride(from: 0, to: cells.count, by: Self.columns).map { start -> NSStackView in
            let row = NSStackView(views: Array(cells[start..<min(start + Self.columns, cells.count)]))
            row.orientation = .horizontal
            row.alignment = .top
            row.distribution = .fillEqually
            row.spacing = 20
            return row
        }
        modes.selectedSegment = isDark ? 1 : 0
        modes.target = self
        modes.action = #selector(modeChanged(_:))
        modes.setAccessibilityIdentifier("cmux.keycapPlayground.mode")
        let column = NSStackView(views: [modes, intro] + rows)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 24
        column.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 24, right: 20)
        column.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedKeycapDocument()
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
            intro.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -40),
        ]
        constraints += rows.map { $0.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -40) }
        NSLayoutConstraint.activate(constraints)
    }

    @objc private func modeChanged(_ sender: NSSegmentedControl) {
        onMode(sender.selectedSegment == 1)
    }
}

/// The playground's document: rows from the top.
private final class FlippedKeycapDocument: NSView {
    nonisolated override var isFlipped: Bool { true }
}
