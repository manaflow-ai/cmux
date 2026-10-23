import AppKit
import CmuxHomeRender
import QuartzCore

/// The empty Chief conversation's first-run panel, between the header and
/// the message box: a short intro to what Chief does, then labels and
/// actions (cmux-next `HomeFirstRunView`). Hidden once the conversation has a
/// message (``ChiefTranscriptView``), with a short fade and lift.
///
/// One centered column for everything, as wide as the widest line of chips
/// (at least 280 pt, at most 560 pt and 48 pt narrower than the panel), so
/// the rows' edges and the chips' edges line up. The rows sit 24 pt above
/// the chips, so the rows, the hint and the chips read as one group over the
/// message box (the composer is the focus: design references
/// `topics/home-and-empty.md`, Codex's prompt starters and Claude's code
/// home; `topics/first-run.md`, Cursor's quiet getting-started card). In a
/// tall pane the group rises up to 24 pt more, so the space under the header
/// is not all void while the group stays anchored to the composer.
/// 0. The intro: a centered title saying what Chief is and one centered
///    sentence on what it does (agents, terminals, Cloud machines and their
///    desktops). Plain text, no glyphs or buttons, 24 pt above the actions.
/// 1. "Open a terminal" and "Start an agent" (when the app wires them), each
///    with its configured shortcut at the trailing edge: bordered buttons.
/// 2. "Your agents": up to five workspaces with an agent, most urgent first,
///    each with a 6 pt status dot and its status word; a click shows the
///    workspace. With no agent anywhere, "Your workspaces": the first five
///    workspaces, "Idle". Borderless, so the section reads as status, not
///    as more buttons.
/// 3. A one-line keyboard hint, "⌃1…9 switches workspaces.", except while
///    Home is selected: there the sidebar's back row already names the way
///    back to the workspaces and its shortcut.
///
/// Pinned just above the message box, three suggestion chips in the
/// incoming bubble's colours, like Messages' suggested replies: one centered
/// row when they fit the column, else 2 + 1 with the third centered
/// (``ChipLines``), never cut.
///
/// Nothing runs under the compose field: chips that do not fit are dropped
/// from the end, then the intro, then agent rows (least urgent first) with
/// their heading, then the hint, then the action rows.
final class ChiefFirstRunView: NSView {
    /// The column's widest; the three chips (about 600 pt) wrap 2 + 1 inside it.
    static let maxWidth: CGFloat = 560
    /// The column's narrowest when the chips' lines are narrower still (a narrow pane).
    static let minWidth: CGFloat = 280
    /// Between the column's last line and the chips.
    static let columnToChips: CGFloat = 24

    /// Whether the host hides the workspace list (Home selected); the sidebar's back row then
    /// names the way back, so the panel shows no hint.
    var hidesWorkspaces = false { didSet { if hidesWorkspaces != oldValue { refreshShortcuts() } } }

    private(set) var starterRows: [ChiefFirstRunRow] = []
    private(set) var actionRows: [ChiefFirstRunRow] = []
    private(set) var agentRows: [ChiefFirstRunRow] = []
    private(set) var agents: [ChiefAgentGlance] = []
    let agentsHeader = NSTextField(labelWithString: ChiefStrings.firstRunAgentsHeader)
    let introTitle = NSTextField(wrappingLabelWithString: ChiefStrings.firstRunIntroTitle)
    let introBody = NSTextField(wrappingLabelWithString: ChiefStrings.firstRunIntroBody)
    let hint = NSTextField(labelWithString: "")
    private let prompts = ChiefStarterPrompt.all

    /// Everything, so the show and hide transitions move one layer.
    private let content = FlippedView()
    private let chipGroup = FlippedView()
    private let observer = ChiefAgentGlanceObserver()

    /// A suggestion chip was picked.
    var onPrompt: (ChiefStarterPrompt) -> Void = { _ in }
    /// An action row was picked.
    var onAction: (ChiefFirstRunAction) -> Void = { _ in }

    /// The column's rows, top to bottom, then the chips.
    var rows: [ChiefFirstRunRow] { actionRows + agentRows + starterRows }
    private var columnRows: [ChiefFirstRunRow] { actionRows + agentRows }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        content.wantsLayer = true
        addSubview(content)

        agentsHeader.font = .systemFont(ofSize: 12, weight: .medium)
        agentsHeader.isSelectable = false
        agentsHeader.lineBreakMode = .byTruncatingTail
        agentsHeader.setAccessibilityRole(.staticText)
        agentsHeader.isHidden = true
        hint.font = .systemFont(ofSize: 12)
        hint.alignment = .center
        hint.isSelectable = false
        hint.lineBreakMode = .byTruncatingTail
        hint.isHidden = true
        content.addSubview(agentsHeader)
        content.addSubview(hint)
        introTitle.font = .systemFont(ofSize: 15, weight: .semibold)
        introBody.font = .systemFont(ofSize: 13)
        for label in [introTitle, introBody] {
            label.alignment = .center
            label.isSelectable = false
            label.setAccessibilityRole(.staticText)
            content.addSubview(label)
        }

        chipGroup.setAccessibilityElement(true)
        chipGroup.setAccessibilityRole(.group)
        chipGroup.setAccessibilityLabel(ChiefStrings.firstRunSuggestions)
        content.addSubview(chipGroup)
        starterRows = prompts.map { prompt in
            let chip = ChiefFirstRunRow(title: prompt.title, leading: .glyph(prompt.symbol), style: .chip)
            chip.onClick = { [weak self] in self?.onPrompt(prompt) }
            chip.onNavigate = { [weak self] row, key in self?.navigate(from: row, key: key) ?? false }
            chip.setAccessibilityHelp(prompt.sends ? ChiefStrings.firstRunSendsHelp : ChiefStrings.firstRunFillsHelp)
            chip.setAccessibilityIdentifier("ChiefFirstRunStarter.\(prompt.symbol)")
            chipGroup.addSubview(chip)
            return chip
        }
        observer.onChange = { [weak self] in self?.refreshAgents() }
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    /// Shows the "Open a terminal" and "Start an agent" rows (or hides them).
    func setShowsActions(_ shows: Bool) {
        guard shows != !actionRows.isEmpty else { return }
        for row in actionRows { row.removeFromSuperview() }
        if shows {
            let terminal = ChiefFirstRunRow(title: ChiefStrings.firstRunOpenTerminal, leading: .glyph("terminal"))
            terminal.onClick = { [weak self] in self?.onAction(.openTerminal) }
            terminal.setAccessibilityIdentifier("ChiefFirstRunAction.terminal")
            let agent = ChiefFirstRunRow(title: ChiefStrings.firstRunStartAgent, leading: .glyph("sparkles"))
            agent.onClick = { [weak self] in self?.onAction(.startAgent) }
            agent.setAccessibilityIdentifier("ChiefFirstRunAction.agent")
            actionRows = [terminal, agent]
            for row in actionRows {
                row.onNavigate = { [weak self] row, key in self?.navigate(from: row, key: key) ?? false }
                content.addSubview(row)
            }
            refreshShortcuts()
        } else {
            actionRows = []
        }
        applyStoredColors()
        needsLayout = true
    }

    // MARK: Agents and shortcuts

    /// Reads the window's agents again; rows are rebuilt only when what they show changed.
    private func refreshAgents() {
        guard let tabManager = observer.tabManager else { return }
        setAgents(ChiefAgentGlanceSource.glances(in: tabManager))
        refreshShortcuts()
    }

    func setAgents(_ list: [ChiefAgentGlance]) {
        let shown = ChiefAgentGlance.shortlist(list)
        guard shown != agents else { return }
        // A rebuild drops the old rows; keep keyboard focus on the same workspace.
        let focused = zip(agents, agentRows).first { window?.firstResponder === $0.1 }?.0.workspaceId
        for row in agentRows { row.removeFromSuperview() }
        agents = shown
        let header = shown.contains(where: \.hasAgent) || shown.isEmpty
            ? ChiefStrings.firstRunAgentsHeader : ChiefStrings.firstRunWorkspacesHeader
        if agentsHeader.stringValue != header { agentsHeader.stringValue = header }
        agentRows = shown.map { glance in
            let row = ChiefFirstRunRow(title: glance.title, leading: .status(glance.status))
            let word = ChiefStrings.firstRunAgentStatus(glance.status)
            row.trailing = word
            row.setAccessibilityValue(word)
            let id = glance.workspaceId
            row.onClick = { [weak self] in
                guard let tabManager = self?.observer.tabManager else { return }
                ChiefAgentGlanceSource.open(id, in: tabManager)
            }
            row.onNavigate = { [weak self] row, key in self?.navigate(from: row, key: key) ?? false }
            row.setAccessibilityIdentifier("ChiefFirstRunAgent.\(id.uuidString)")
            content.addSubview(row)
            return row
        }
        applyStoredColors()
        needsLayout = true
        if let focused {
            window?.makeFirstResponder(zip(shown, agentRows).first { $0.0.workspaceId == focused }?.1 ?? actionRows.last)
        }
    }

    /// The rows' shortcuts and the hint's keys, as configured now (cmux.json overrides included).
    private func refreshShortcuts() {
        if let terminal = actionRows.first {
            let keys = ChiefAgentGlanceSource.newWorkspaceKeys()
            terminal.trailing = keys
            terminal.setAccessibilityHelp(keys)
        }
        // On Home the sidebar's back row ("‹ Workspaces", with the Open Chief shortcut) is the way
        // back; a hint repeating it would make one action appear twice on one screen.
        let hintText = hidesWorkspaces ? ""
            : ChiefAgentGlanceSource.workspaceNumberKeys().map(ChiefStrings.firstRunWorkspacesHint) ?? ""
        if hint.stringValue != hintText {
            hint.stringValue = hintText
            needsLayout = true
        }
    }

    /// Follows the window's agents only while the panel is on screen.
    private func updateObservation() {
        if window != nil, !wantsHidden {
            observer.attach(ChiefAgentGlanceSource.tabManager(for: window))
            refreshAgents()
        } else {
            observer.detach()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateObservation()
    }

    // MARK: Colours

    private var theme: ChiefTheme?

    func apply(_ theme: ChiefTheme) {
        self.theme = theme
        // System tints (status dots, the focus ring) resolve for the terminal theme, not the OS.
        appearance = theme.appearance
        applyStoredColors()
    }

    private func applyStoredColors() {
        guard let theme else { return }
        agentsHeader.textColor = theme.textTertiary
        hint.textColor = theme.textTertiary
        introTitle.textColor = theme.textPrimary
        introBody.textColor = theme.textSecondary
        let pressed = theme.mix(theme.isDark ? 0.17 : 0.11)
        let rowColors = ChiefFirstRunRow.Colors(text: theme.textPrimary, glyph: theme.textSecondary,
                                                trailing: theme.textTertiary, fill: theme.raisedFill,
                                                hover: theme.hoverFill, pressed: pressed, border: theme.hairline)
        for row in actionRows { row.applyColors(rowColors) }
        // Status rows: no fill and no border until the pointer is over them.
        var statusColors = rowColors
        statusColors.fill = .clear
        statusColors.border = nil
        for row in agentRows { row.applyColors(statusColors) }
        let palette = theme.palettes().active
        let bubble = NSColor(cgColor: palette.incomingBubble.cgColor) ?? theme.raisedFill
        let bubbleText = NSColor(cgColor: palette.incomingText.cgColor) ?? theme.textPrimary
        let chipColors = ChiefFirstRunRow.Colors(
            text: bubbleText, glyph: theme.textSecondary, trailing: theme.textTertiary, fill: bubble,
            hover: bubble.blended(withFraction: theme.isDark ? 0.08 : 0.06, of: theme.foreground) ?? bubble,
            pressed: bubble.blended(withFraction: theme.isDark ? 0.16 : 0.12, of: theme.foreground) ?? bubble,
            border: nil)
        for chip in starterRows { chip.applyColors(chipColors) }
    }

    // MARK: Show and hide

    /// The state the transcript asked for; the view stays on screen while it fades out.
    private var wantsHidden = false
    private var transition = 0

    /// Hiding fades the panel out and lifts it a little as the first message
    /// arrives; showing fades it in. Reading `isHidden` returns the requested
    /// state at once, so callers that compare it keep working.
    override var isHidden: Bool {
        get { wantsHidden }
        set {
            guard newValue != wantsHidden else { return }
            wantsHidden = newValue
            animateVisibility(hidden: newValue)
            updateObservation()
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        wantsHidden ? nil : super.hitTest(point)
    }

    private func animateVisibility(hidden: Bool) {
        transition += 1
        let token = transition
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard window != nil, !(hidden && super.isHidden) else {
            super.isHidden = hidden
            alphaValue = 1
            return
        }
        if hidden {
            if let first = window?.firstResponder as? ChiefFirstRunRow, rows.contains(first) {
                window?.makeFirstResponder(nil)
            }
            lift(from: 0, to: reduceMotion ? 0 : -8, duration: 0.2)
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = reduceMotion ? 0.12 : 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.transition == token, self.wantsHidden else { return }
                    self.finishHiding()
                }
            })
        } else {
            alphaValue = 0
            super.isHidden = false
            lift(from: reduceMotion ? 0 : 6, to: 0, duration: 0.28)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = reduceMotion ? 0.12 : 0.24
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                animator().alphaValue = 1
            }
        }
    }

    private func finishHiding() {
        super.isHidden = true
        alphaValue = 1
        content.layer?.removeAnimation(forKey: Self.liftKey)
    }

    private static let liftKey = "chief.firstRun.lift"

    /// A vertical drift of the content layer (presentation only; the model stays put).
    private func lift(from: CGFloat, to: CGFloat, duration: CFTimeInterval) {
        guard let layer = content.layer, from != to else { return }
        // Positive is down in a flipped superlayer (AppKit flips the layers of flipped views).
        let flip: CGFloat = (layer.superlayer?.contentsAreFlipped() ?? true) ? 1 : -1
        let animation = CABasicAnimation(keyPath: "transform.translation.y")
        animation.fromValue = from * flip
        animation.toValue = to * flip
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
        animation.fillMode = .forwards
        animation.isRemovedOnCompletion = to == 0
        layer.add(animation, forKey: Self.liftKey)
    }

    // MARK: Keyboard

    /// Up and Down move through the column and on to the chips; Left and
    /// Right move between chips.
    private func navigate(from row: ChiefFirstRunRow, key: UInt16) -> Bool {
        let column = columnRows.filter { !$0.isHiddenOrHasHiddenAncestor }
        let chips = starterRows.filter { !$0.isHiddenOrHasHiddenAncestor }
        let rtl = userInterfaceLayoutDirection == .rightToLeft
        let left: UInt16 = 123, right: UInt16 = 124, down: UInt16 = 125, up: UInt16 = 126
        var target: ChiefFirstRunRow?
        if let index = column.firstIndex(where: { $0 === row }) {
            if key == up, index > 0 { target = column[index - 1] }
            if key == down { target = index + 1 < column.count ? column[index + 1] : chips.first }
        } else if let index = chips.firstIndex(where: { $0 === row }) {
            let step = key == right ? (rtl ? -1 : 1) : key == left ? (rtl ? 1 : -1) : 0
            if step != 0, chips.indices.contains(index + step) { target = chips[index + step] }
            if key == up { target = column.last }
        }
        guard let target else { return false }
        window?.makeFirstResponder(target)
        return true
    }

    /// Tab order: the column top to bottom, then the chips.
    private func chainKeyViews() {
        let visible = rows.filter { !$0.isHiddenOrHasHiddenAncestor }
        for (index, row) in visible.enumerated() {
            row.nextKeyView = visible.indices.contains(index + 1) ? visible[index + 1] : nil
        }
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        content.frame = bounds
        let rtl = userInterfaceLayoutDirection == .rightToLeft

        // One column for the rows and the chips: as wide as the widest line
        // of chips, so the edges line up (the chips keep their lines when
        // laid out again in it, each line no wider than the column).
        let available = max(0, min(Self.maxWidth, bounds.width - 48))
        let chipGap: CGFloat = 8, chipBottom: CGFloat = 12
        let chipWidths = starterRows.map(\.chipWidth)
        let widest = ChipLines(gap: chipGap).layout(widths: chipWidths, available: available)
            .map { line in (line.last.map { $0.x + $0.width } ?? 0) - (line.first?.x ?? 0) }.max() ?? 0
        let width = min(available, max(widest, Self.minWidth))
        let x = floor((bounds.width - width) / 2)
        // Chips: centered lines just above the field.
        let lines = ChipLines(gap: chipGap).layout(widths: chipWidths, available: width)
        let chipHeight = ChiefFirstRunRow.chipHeight
        let minimumColumn: CGFloat = 2 * ChiefFirstRunRow.height + 6
        // Lines that would leave no room for the action rows go, last first.
        var shownLines = lines.count
        func chipsHeight(_ count: Int) -> CGFloat {
            count == 0 ? 0 : CGFloat(count) * chipHeight + CGFloat(count - 1) * chipGap + chipBottom
        }
        while shownLines > 0, chipsHeight(shownLines) + (actionRows.isEmpty ? 0 : minimumColumn + Self.columnToChips) > bounds.height {
            shownLines -= 1
        }
        let groupHeight = shownLines == 0 ? 0 : chipsHeight(shownLines) - chipBottom
        chipGroup.frame = CGRect(x: x, y: bounds.height - chipBottom - groupHeight, width: width, height: groupHeight)
        setHidden(chipGroup, shownLines == 0)
        for (lineIndex, line) in lines.enumerated() {
            for placed in line {
                let chip = starterRows[placed.index]
                // Right to left mirrors each centered line.
                let chipX = rtl ? width - placed.x - placed.width : placed.x
                setHidden(chip, lineIndex >= shownLines)
                chip.frame = CGRect(x: chipX, y: CGFloat(lineIndex) * (chipHeight + chipGap), width: placed.width, height: chipHeight)
            }
        }

        // The column: bottom-aligned 24 pt above the chips (or the field),
        // so the rows, the hint and the chips read as one group over the
        // composer instead of islands spread down a tall pane; the header
        // stays at the top. Blocks that do not fit go, as below.
        let room = (shownLines == 0 ? bounds.height - chipBottom : chipGroup.frame.minY) - Self.columnToChips
        let row = ChiefFirstRunRow.height, gap: CGFloat = 6, group: CGFloat = 14
        let headerHeight = ceil(agentsHeader.intrinsicContentSize.height)
        let hintHeight = ceil(hint.intrinsicContentSize.height)
        // The intro wraps inside the column, 12 pt in like the rows' text.
        let introGap: CGFloat = 6, introToActions: CGFloat = 24, introWidth = max(0, width - 24)
        let titleHeight = Self.wrappedHeight(introTitle, width: introWidth)
        let bodyHeight = Self.wrappedHeight(introBody, width: introWidth)
        let introHeight = titleHeight + introGap + bodyHeight
        var showsIntro = true
        var showsActions = !actionRows.isEmpty
        var showsHint = !hint.stringValue.isEmpty
        var agentCount = agentRows.count

        func columnHeight() -> CGFloat {
            var height: CGFloat = 0
            var blocks = 0
            if showsIntro {
                height += introHeight
                blocks += 1
            }
            if showsActions {
                height += (blocks > 0 ? introToActions : 0) + CGFloat(actionRows.count) * row
                    + CGFloat(actionRows.count - 1) * gap
                blocks += 1
            }
            if agentCount > 0 {
                height += (blocks > 0 ? group : 0) + headerHeight + gap + CGFloat(agentCount) * row
                    + CGFloat(agentCount - 1) * gap
                blocks += 1
            }
            if showsHint {
                height += (blocks > 0 ? group : 0) + hintHeight
            }
            return height
        }
        // The intro explains; live agent rows outrank it.
        if columnHeight() > room { showsIntro = false }
        while agentCount > 0, columnHeight() > room { agentCount -= 1 }
        if columnHeight() > room { showsHint = false }
        if columnHeight() > room { showsActions = false }

        let column = columnHeight()
        // A tall pane: rise up to 24 pt more once the space above passes
        // 120 pt, so the void under the header shrinks while the group
        // stays close to the composer.
        let lift = min(24, max(0, room - column - 120) / 4)
        var y = max(0, floor(room - column - lift))
        var placedBlock = false
        setHidden(introTitle, !showsIntro)
        setHidden(introBody, !showsIntro)
        if showsIntro {
            introTitle.frame = CGRect(x: x + 12, y: y, width: introWidth, height: titleHeight)
            y += titleHeight + introGap
            introBody.frame = CGRect(x: x + 12, y: y, width: introWidth, height: bodyHeight)
            y += bodyHeight
            placedBlock = true
        }
        for (index, actionRow) in actionRows.enumerated() {
            setHidden(actionRow, !showsActions)
            guard showsActions else { continue }
            if index == 0, placedBlock { y += introToActions }
            if index > 0 { y += gap }
            actionRow.frame = CGRect(x: x, y: y, width: width, height: row)
            y += row
            placedBlock = true
        }
        setHidden(agentsHeader, agentCount == 0)
        if agentCount > 0 {
            if placedBlock { y += group }
            agentsHeader.alignment = rtl ? .right : .left
            // In line with the rows' leading glyphs and dots (12 pt in).
            agentsHeader.frame = CGRect(x: x + 12, y: y, width: max(0, width - 24), height: headerHeight)
            y += headerHeight + gap
            placedBlock = true
        }
        for (index, agentRow) in agentRows.enumerated() {
            setHidden(agentRow, index >= agentCount)
            guard index < agentCount else { continue }
            if index > 0 { y += gap }
            agentRow.frame = CGRect(x: x, y: y, width: width, height: row)
            y += row
        }
        setHidden(hint, !showsHint)
        if showsHint {
            if placedBlock { y += group }
            hint.frame = CGRect(x: x, y: y, width: width, height: hintHeight)
        }
        for columnRow in columnRows { columnRow.width = width }
        chainKeyViews()
    }

    /// The height `label` needs at `width`, wrapping.
    private static func wrappedHeight(_ label: NSTextField, width: CGFloat) -> CGFloat {
        guard width > 0, let cell = label.cell else { return 0 }
        return ceil(cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)).height)
    }

    private func setHidden(_ view: NSView, _ hidden: Bool) {
        if view.isHidden != hidden { view.isHidden = hidden }
    }
}

/// A plain top-left-origin container.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
