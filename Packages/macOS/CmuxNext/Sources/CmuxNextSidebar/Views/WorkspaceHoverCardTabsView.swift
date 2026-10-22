import AppKit
import CmuxNextDesign

/// The workspace hover card's tab list (u9696): every tab in pane and tab order, a header per pane
/// when there is more than one, at most ``limit`` tab rows, then how many more. It reads the row's
/// cached tabs as given and maps nothing; its row, header and "more" views are made once and reused
/// card to card, so a hover after the first makes no view.
final class WorkspaceHoverCardTabsView: NSView {
    /// The tab rows the list shows before its "more" row.
    let limit: Int
    private let stack = NSStackView()
    private var rows: [WorkspaceHoverCardTabRowView] = []
    private var headers: [ChromeLabel] = []
    private let moreLabel = ChromeLabel(labelWithString: "")
    /// Every row, header and "more" view made so far (tests: a hover reuses them).
    private(set) var viewsMade = 1
    /// Selects a tab (a click on its row); the card's controller sets it.
    var onSelectTab: ((TabID) -> Void)?

    init(limit: Int) {
        self.limit = limit
        super.init(frame: .zero)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Metrics.space2
        stack.translatesAutoresizingMaskIntoConstraints = false
        moreLabel.font = Typography.caption
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows `tabs` (a header per pane when they span more than one).
    func configure(_ tabs: [SidebarTab]) {
        let grouped = tabs.contains { $0.pane != tabs.first?.pane }
        let shown = min(tabs.count, limit)
        var order: [NSView] = []
        order.reserveCapacity(shown * 2 + 1)
        var headerCount = 0
        var lastPane: UInt16?
        for index in 0..<shown {
            let tab = tabs[index]
            if grouped, tab.pane != lastPane {
                let header = header(at: headerCount)
                header.stringValue = Strings.paneHeader(Int(tab.pane) + 1)
                headerCount += 1
                order.append(header)
                lastPane = tab.pane
            }
            let row = row(at: index)
            row.configure(tab)
            order.append(row)
        }
        if tabs.count > shown {
            moreLabel.stringValue = Strings.statusMore(tabs.count - shown)
            order.append(moreLabel)
        }
        // Only a list that changed shape re-arranges the stack: the same shape keeps its views.
        if stack.arrangedSubviews != order {
            for view in stack.arrangedSubviews where !order.contains(where: { $0 === view }) {
                stack.removeArrangedSubview(view)
                view.removeFromSuperview()
            }
            for (index, view) in order.enumerated() {
                if index < stack.arrangedSubviews.count, stack.arrangedSubviews[index] === view { continue }
                if view.superview === stack { stack.removeArrangedSubview(view) }
                stack.insertArrangedSubview(view, at: index)
                // A row spans the list (its text truncates there); taking it out of the stack dropped its pin.
                if let row = view as? WorkspaceHoverCardTabRowView, row.widthPin?.isActive != true {
                    row.widthPin = row.widthAnchor.constraint(equalTo: stack.widthAnchor)
                    row.widthPin?.isActive = true
                }
            }
        }
    }

    private func row(at index: Int) -> WorkspaceHoverCardTabRowView {
        while rows.count <= index {
            let row = WorkspaceHoverCardTabRowView()
            row.translatesAutoresizingMaskIntoConstraints = false
            rows.append(row)
            viewsMade += 1
            row.applyColors()
        }
        return rows[index]
    }

    private func header(at index: Int) -> ChromeLabel {
        while headers.count <= index {
            let label = ChromeLabel(labelWithString: "")
            label.font = Typography.caption
            headers.append(label)
            viewsMade += 1
        }
        return headers[index]
    }

    /// Rows arranged now, in order.
    private var shownRows: [WorkspaceHoverCardTabRowView] {
        stack.arrangedSubviews.compactMap { $0 as? WorkspaceHoverCardTabRowView }
    }

    /// The text the list shows, one entry per row (tests, `debug.hover_cards`).
    var lines: [String] {
        stack.arrangedSubviews.map { ($0 as? WorkspaceHoverCardTabRowView)?.shownText ?? ($0 as? ChromeLabel)?.stringValue ?? "" }
    }

    /// The `index`th shown tab row's frame on screen (tests).
    func rowFrameOnScreen(at index: Int) -> CGRect? {
        let rows = shownRows
        guard index < rows.count, let window else { return nil }
        let row = rows[index]
        return window.convertToScreen(row.convert(row.bounds, to: nil))
    }

    /// Selects the tab whose row is under `screenPoint`; false when no row is.
    func click(atScreen screenPoint: CGPoint) -> Bool {
        guard let window, !isHidden else { return false }
        let inWindow = window.convertPoint(fromScreen: screenPoint)
        for row in shownRows {
            guard let id = row.tabID, row.convert(row.bounds, to: nil).contains(inWindow) else { continue }
            onSelectTab?(id)
            return true
        }
        return false
    }

    func applyColors() {
        performWithTheme {
            for header in headers { header.textColor = Palette.textSecondary }
            moreLabel.textColor = Palette.textSecondary
        }
        for row in rows { row.applyColors() }
    }
}
