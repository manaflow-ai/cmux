import AppKit

/// The Tooltip Gallery's content: a line on what it shows, then one column per theme
/// (``TooltipGallerySheet``), side by side, in one scrolling view.
@MainActor
final class TooltipGalleryView: NSView {
    private(set) var sheets: [TooltipGallerySheet] = []
    let scrollView = OverlayScrollView()

    /// - Parameter columns: Each column's name, appearance and theme.
    init(columns: [(title: String, isDark: Bool, theme: (spec: ThemeSpec?, input: ThemeInput)?)]) {
        super.init(frame: .zero)
        sheets = columns.map { TooltipGallerySheet(title: $0.title, isDark: $0.isDark, theme: $0.theme) }
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") } // crash-allow: never decoded from a nib

    private func build() {
        let intro = ThemedLabel(wrappingLabelWithString:
            "Every tooltip in cmux, native and pages: the control's name in regular 12 pt text in the tooltip ink, the "
            + "shortcut's keys on the dialogs' keycap 4 pt in from the top, bottom and end, one line and one height with "
            + "or without keys, an ellipsis past 320 pt, below its control and flipping above at the screen's edge, "
            + "shown and hidden in one frame. A control that shows its own text and a row with a hover card have none.")
        intro.font = Typography.body
        intro.themeColor = { Palette.textSecondary }
        let row = NSStackView(views: sheets.map { cell($0) })
        row.orientation = .horizontal
        row.alignment = .top
        row.distribution = .fillEqually
        row.spacing = 20
        let column = NSStackView(views: [intro, row])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 20
        column.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 24, right: 20)
        column.translatesAutoresizingMaskIntoConstraints = false
        let document = TooltipGalleryDocument()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(column)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.documentView = document
        addSubview(scrollView)
        NSLayoutConstraint.activate([
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
            row.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -40),
        ])
    }

    private func cell(_ sheet: TooltipGallerySheet) -> NSView {
        let title = ThemedLabel(labelWithString: sheet.title)
        title.font = Typography.system(size: TypeScale.body, weight: TypeScale.emphasis)
        title.themeColor = { Palette.textPrimary }
        let stack = NSStackView(views: [title, sheet])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        sheet.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }
}

/// The gallery's document: rows from the top.
private final class TooltipGalleryDocument: NSView {
    nonisolated override var isFlipped: Bool { true }
}
