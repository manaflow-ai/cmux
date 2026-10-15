import AppKit

/// The empty Chief conversation's first-run panel, between the header and
/// the message box: a short headline, starter requests that fill (and most
/// send) the message, then, when the app wires them, "Open a terminal" and
/// "Start an agent". Labels and actions only. Hidden once the conversation
/// has a message (``ChiefTranscriptView``).
///
/// Layout follows cmux-next's `HomeFirstRunView`: a centered column at most
/// 340 pt wide (48 pt narrower than the panel), 28 pt rows 6 pt apart, 14 pt
/// between groups; rows that do not fit above the field are dropped from the
/// end, so the panel never runs under the compose field.
final class ChiefFirstRunView: NSView {
    static let maxWidth: CGFloat = 340

    let headline = NSTextField(labelWithString: ChiefStrings.firstRunHeadline)
    private(set) var starterRows: [ChiefFirstRunRow] = []
    private(set) var actionRows: [ChiefFirstRunRow] = []
    private let stack = NSStackView()
    private let prompts = ChiefStarterPrompt.all

    /// A starter row was picked.
    var onPrompt: (ChiefStarterPrompt) -> Void = { _ in }
    /// An action row was picked.
    var onAction: (ChiefFirstRunAction) -> Void = { _ in }

    var rows: [ChiefFirstRunRow] { starterRows + actionRows }

    override init(frame: NSRect) {
        super.init(frame: frame)
        headline.font = .systemFont(ofSize: 20, weight: .semibold)
        headline.alignment = .center
        headline.isSelectable = false
        headline.lineBreakMode = .byTruncatingTail
        headline.setAccessibilityRole(.staticText)
        starterRows = prompts.map { prompt in
            let row = ChiefFirstRunRow(title: prompt.title, symbol: prompt.symbol,
                                       help: prompt.sends ? ChiefStrings.firstRunSendsHelp : ChiefStrings.firstRunFillsHelp)
            row.onClick = { [weak self] in self?.onPrompt(prompt) }
            return row
        }
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        addSubview(stack)
        arrange()
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    /// Shows the "Open a terminal" and "Start an agent" rows (or hides them).
    func setShowsActions(_ shows: Bool) {
        guard shows != !actionRows.isEmpty else { return }
        if shows {
            let terminal = ChiefFirstRunRow(title: ChiefStrings.firstRunOpenTerminal, symbol: "terminal", help: nil)
            terminal.onClick = { [weak self] in self?.onAction(.openTerminal) }
            let agent = ChiefFirstRunRow(title: ChiefStrings.firstRunStartAgent, symbol: "sparkles", help: nil)
            agent.onClick = { [weak self] in self?.onAction(.startAgent) }
            actionRows = [terminal, agent]
        } else {
            actionRows = []
        }
        arrange()
        applyStoredColors()
        needsLayout = true
    }

    private func arrange() {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for view in [headline] + starterRows + actionRows as [NSView] { stack.addArrangedSubview(view) }
        stack.setCustomSpacing(18, after: headline)
        if let last = starterRows.last, !actionRows.isEmpty { stack.setCustomSpacing(14, after: last) }
    }

    // MARK: Colours

    private var theme: ChiefTheme?

    func apply(_ theme: ChiefTheme) {
        self.theme = theme
        applyStoredColors()
    }

    private func applyStoredColors() {
        guard let theme else { return }
        headline.textColor = theme.textPrimary
        for row in rows {
            row.applyColors(text: theme.textPrimary, glyphTint: theme.textSecondary, fill: theme.raisedFill,
                            hover: theme.hoverFill, border: theme.hairline)
        }
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        let width = max(0, min(Self.maxWidth, bounds.width - 48))
        for row in rows { row.width = width }
        fitRows()
        let size = stack.fittingSize
        stack.frame = CGRect(x: (bounds.width - width) / 2, y: max(0, (bounds.height - size.height) / 2),
                             width: width, height: size.height)
    }

    /// Keeps the rows that fit, dropping from the end (action rows, then the
    /// last starters); with no room for one row the headline goes too.
    /// `isHidden` changes only when the count that fits does.
    private func fitRows() {
        let headlineHeight = ceil(headline.intrinsicContentSize.height) + 18
        let row = ChiefFirstRunRow.height, gap: CGFloat = 6, group: CGFloat = 14
        var used = headlineHeight
        var shown = 0
        for (index, _) in rows.enumerated() {
            let spacing: CGFloat = index == 0 ? 0 : (index == starterRows.count ? group : gap)
            guard used + spacing + row <= bounds.height else { break }
            used += spacing + row
            shown += 1
        }
        for (index, view) in rows.enumerated() where view.isHidden != (index >= shown) { view.isHidden = index >= shown }
        let hideHeadline = shown == 0
        if headline.isHidden != hideHeadline { headline.isHidden = hideHeadline }
    }
}
