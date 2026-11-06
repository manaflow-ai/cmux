public import AppKit
import CmuxNextCompat
public import CmuxNextDesign

/// The Automations page (docs/automations-platonic-ideal.md section 8, option A): a list grouped
/// Needs you / Today / Later / Paused on the left, the selected automation's detail and run
/// history on the right. Rows get value snapshots and closures only (the list snapshot rule).
///
/// AppKit (plans/cmux-next/no-swiftui-DESIGN.md): the page follows its model while it is in a
/// window, and redraws in a new palette when ``palette`` is set.
public final class AutomationsPageView: NSView {
    /// What the page's buttons do; the app routes each to the shared automation op.
    public struct Actions: Sendable {
        /// The header's New button; nil hides it (no create form yet).
        public var new: (@MainActor @Sendable () -> Void)?
        /// Omit an operation until the hosting app supplies a real handler.
        public var runNow: (@MainActor @Sendable (AutomationRow) -> Void)?
        public var setEnabled: (@MainActor @Sendable (AutomationRow, Bool) -> Void)?
        public var edit: (@MainActor @Sendable (AutomationRow) -> Void)?
        /// Sign In beside "Sign in to cmux to see your Cloud automations" (the shared ``SignInButton``);
        /// nil shows the line alone.
        public var signIn: (@MainActor @Sendable () -> Void)?

        public init(new: (@MainActor @Sendable () -> Void)? = nil,
                    runNow: (@MainActor @Sendable (AutomationRow) -> Void)? = nil,
                    setEnabled: (@MainActor @Sendable (AutomationRow, Bool) -> Void)? = nil,
                    edit: (@MainActor @Sendable (AutomationRow) -> Void)? = nil,
                    signIn: (@MainActor @Sendable () -> Void)? = nil) {
            self.new = new
            self.runNow = runNow
            self.setEnabled = setEnabled
            self.edit = edit
            self.signIn = signIn
        }
    }

    private let page: AutomationsPage
    private let actions: Actions
    private let fixedNow: Date?
    private let strings = AutomationStrings()
    /// The colors and type the page draws in; setting a different one redraws it.
    public var palette: AutomationsPalette {
        didSet { if palette != oldValue { render() } }
    }

    private let content = NSStackView()
    private let listStack = NSStackView()
    private let listScroll = NSScrollView()
    // task-owner: the page's `following`, started when it joins a window and cancelled when it leaves.
    private var following: Task<Void, Never>?

    /// The list's width.
    static let listWidth: CGFloat = 320

    /// Makes the page view.
    ///
    /// - Parameters:
    ///   - page: The model.
    ///   - palette: The hosting window's colors and type.
    ///   - now: The time sections and relative times are drawn for; nil is the time of each draw.
    ///   - actions: What the buttons do.
    public init(page: AutomationsPage, palette: AutomationsPalette, now: Date? = nil, actions: Actions = Actions()) {
        self.page = page
        self.palette = palette
        self.fixedNow = now
        self.actions = actions
        super.init(frame: NSRect(x: 0, y: 0, width: 760, height: 440))
        wantsLayer = true
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 0
        content.distribution = .fill
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor), content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor), content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 0
        listStack.translatesAutoresizingMaskIntoConstraints = false
        let document = AutomationsFlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(listStack)
        listScroll.documentView = document
        listScroll.drawsBackground = false
        listScroll.hasVerticalScroller = true
        listScroll.translatesAutoresizingMaskIntoConstraints = false
        listScroll.widthAnchor.constraint(equalToConstant: Self.listWidth).isActive = true
        NSLayoutConstraint.activate([
            listStack.leadingAnchor.constraint(equalTo: document.leadingAnchor), listStack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            listStack.topAnchor.constraint(equalTo: document.topAnchor), listStack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.widthAnchor.constraint(equalTo: listScroll.contentView.widthAnchor),
        ])
        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var isFlipped: Bool { true }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        following?.cancel()
        following = nil
        guard window != nil else { return }
        render()
        let page = page
        following = Task { [weak self] in
            for await _ in ObservationStream({ _ = page.rows; _ = page.selection; _ = page.problems }) {
                guard let self, !Task.isCancelled else { return }
                self.render()
            }
        }
    }

    // MARK: Drawing

    /// Draws the page from the model: the header, a line per source that did not load, then the
    /// empty line or the list beside the selected automation's detail.
    func render() {
        let now = fixedNow ?? .now
        layer?.backgroundColor = palette.background.cgColor
        for view in content.arrangedSubviews { view.removeFromSuperview() }
        add(header(), height: 44)
        add(divider(.horizontal))
        for line in problemLines() { add(line) }
        if page.rows.isEmpty {
            let empty = label(strings.empty, font: palette.body, color: palette.secondary)
            empty.alignment = .center
            let fill = NSView()
            fill.translatesAutoresizingMaskIntoConstraints = false
            empty.translatesAutoresizingMaskIntoConstraints = false
            fill.addSubview(empty)
            NSLayoutConstraint.activate([empty.centerXAnchor.constraint(equalTo: fill.centerXAnchor),
                                         empty.centerYAnchor.constraint(equalTo: fill.centerYAnchor)])
            add(fill, fills: true)
        } else {
            renderList(now: now)
            let split = NSStackView(views: [listScroll, divider(.vertical), detail(now: now)])
            split.orientation = .horizontal
            split.alignment = .top
            split.spacing = 0
            split.distribution = .fill
            add(split, fills: true)
            NSLayoutConstraint.activate([listScroll.heightAnchor.constraint(equalTo: split.heightAnchor)])
            if let rule = split.arrangedSubviews.dropFirst().first {
                rule.heightAnchor.constraint(equalTo: split.heightAnchor).isActive = true
            }
        }
    }

    private func add(_ view: NSView, height: CGFloat? = nil, fills: Bool = false) {
        content.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        if let height { view.heightAnchor.constraint(equalToConstant: height).isActive = true }
        if fills {
            view.setContentHuggingPriority(.init(1), for: .vertical)
            view.setContentCompressionResistancePriority(.init(1), for: .vertical)
        }
    }

    private func header() -> NSView {
        let title = label(strings.title, font: palette.header, color: palette.text)
        let chip = AutomationChip(text: strings.active(page.rows.filter(\.enabled).count), palette: palette)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        var views: [NSView] = [title, chip, spacer]
        if actions.new != nil {
            let new = button(strings.new, prominent: true, small: true) { [actions] in actions.new?() }
            views.append(new)
        }
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        return row
    }

    /// One line per source that did not load, so a failure never reads as "no automations".
    private func problemLines() -> [NSView] {
        [AutomationRow.Target.thisMac, .cloud].compactMap { target in
            guard let code = page.problems[target] else { return nil }
            var views: [NSView] = [label(strings.problem(target, code: code), font: palette.caption, color: palette.attention)]
            if let signIn = Self.signIn(for: target, code: code, actions: actions) {
                views.append(SignInButton { signIn() })
            }
            let line = NSStackView(views: views)
            line.orientation = .horizontal
            line.alignment = .centerY
            line.spacing = 8
            line.edgeInsets = NSEdgeInsets(top: 4, left: 16, bottom: 4, right: 16)
            line.setHuggingPriority(.init(1), for: .horizontal)
            return line
        }
    }

    /// The Sign In a problem line offers: only Cloud's signed-out line, and only when the app gave one.
    static func signIn(for target: AutomationRow.Target, code: String, actions: Actions) -> (@MainActor @Sendable () -> Void)? {
        target == .cloud && code == "automation.signed_out" ? actions.signIn : nil
    }

    private func renderList(now: Date) {
        for view in listStack.arrangedSubviews { view.removeFromSuperview() }
        for (section, rows) in page.sections(now: now) {
            let heading = label(strings.section(section).uppercased(), font: palette.caption, color: palette.tertiary)
            let wrap = NSStackView(views: [heading])
            wrap.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 4, right: 16)
            listStack.addArrangedSubview(wrap)
            for row in rows {
                let view = AutomationListRow(row: row, selected: row.id == page.selection, palette: palette, strings: strings, now: now) {
                    [weak page] in page?.selection = row.id
                }
                listStack.addArrangedSubview(view)
                view.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
            }
        }
    }

    private func detail(now: Date) -> NSView {
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 10
        column.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        column.setHuggingPriority(.init(1), for: .horizontal)
        guard let row = page.selected else { return column }
        column.addArrangedSubview(label(row.name, font: palette.header, color: palette.text))

        var facts: [NSView] = [label(row.schedule, font: palette.caption, color: palette.secondary),
                               AutomationChip(text: strings.target(row.target), palette: palette)]
        if let next = row.nextRun, row.enabled {
            facts.append(label(strings.next(Self.time(next, now: now)), font: palette.caption, color: palette.secondary))
        }
        column.addArrangedSubview(stack(facts, spacing: 6))

        let task = label(row.task, font: palette.body, color: palette.text)
        task.maximumNumberOfLines = 0
        task.lineBreakMode = .byWordWrapping
        task.translatesAutoresizingMaskIntoConstraints = false
        let card = NSView()
        card.wantsLayer = true
        card.layer?.cornerRadius = Metrics.insetCornerRadius
        card.layer?.backgroundColor = palette.card.cgColor
        card.layer?.borderColor = palette.separator.cgColor
        card.layer?.borderWidth = 1
        card.addSubview(task)
        NSLayoutConstraint.activate([
            task.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 10),
            task.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10),
            task.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            task.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10),
        ])
        column.addArrangedSubview(card)
        card.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -32).isActive = true

        var buttons: [NSView] = []
        if let runNow = actions.runNow { buttons.append(button(strings.runNow, prominent: true, small: true) { runNow(row) }) }
        if let setEnabled = actions.setEnabled {
            buttons.append(button(row.enabled ? strings.pause : strings.resume, small: true) { setEnabled(row, !row.enabled) })
        }
        if let edit = actions.edit { buttons.append(button(strings.edit, small: true) { edit(row) }) }
        if !buttons.isEmpty { column.addArrangedSubview(stack(buttons, spacing: 6)) }

        let history = label(strings.history.uppercased(), font: palette.caption, color: palette.tertiary)
        column.addArrangedSubview(history)
        column.setCustomSpacing(10 + 6, after: column.arrangedSubviews[column.arrangedSubviews.count - 2])
        if row.runs.isEmpty {
            column.addArrangedSubview(label(strings.noRuns, font: palette.caption, color: palette.secondary))
        }
        for run in row.runs.prefix(8) {
            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 3.5
            dot.layer?.backgroundColor = palette.color(run.result).cgColor
            dot.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([dot.widthAnchor.constraint(equalToConstant: 7), dot.heightAnchor.constraint(equalToConstant: 7)])
            var parts: [NSView] = [dot, label(Self.time(run.at, now: now), font: palette.caption, color: palette.text)]
            if run.lateSeconds > 120 {
                parts.append(label(strings.late(run.lateSeconds / 60), font: palette.caption, color: palette.attention))
            }
            if let reason = run.reason { parts.append(label(reason, font: palette.caption, color: palette.secondary)) }
            let line = stack(parts, spacing: 8)
            line.edgeInsets = NSEdgeInsets(top: 3, left: 0, bottom: 3, right: 0)
            column.addArrangedSubview(line)
            let rule = divider(.horizontal)
            column.addArrangedSubview(rule)
            rule.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -32).isActive = true
        }
        return column
    }

    // MARK: Parts

    private func label(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    private func stack(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = spacing
        return stack
    }

    private func divider(_ axis: NSUserInterfaceLayoutOrientation) -> NSView {
        let rule = NSView()
        rule.wantsLayer = true
        rule.layer?.backgroundColor = palette.separator.cgColor
        rule.translatesAutoresizingMaskIntoConstraints = false
        let thickness = axis == .horizontal ? rule.heightAnchor : rule.widthAnchor
        thickness.constraint(equalToConstant: 1).isActive = true
        return rule
    }

    private func button(_ title: String, prominent: Bool = false, small: Bool, action: @escaping @MainActor () -> Void) -> NSButton {
        let button = AutomationsActionButton(title: title, action: action)
        button.bezelStyle = .push
        button.controlSize = small ? .small : .regular
        if prominent { button.bezelColor = .controlAccentColor }
        return button
    }

    /// `Fri 9:00`, or `9:00` today.
    static func time(_ date: Date, now: Date) -> String {
        let style: Date.FormatStyle = Calendar.current.isDate(date, inSameDayAs: now)
            ? .dateTime.hour().minute()
            : .dateTime.weekday(.abbreviated).hour().minute()
        return date.formatted(style)
    }
}

/// A button that runs a closure.
private final class AutomationsActionButton: NSButton {
    private let run: @MainActor () -> Void

    init(title: String, action: @escaping @MainActor () -> Void) {
        run = action
        super.init(frame: .zero)
        self.title = title
        target = self
        self.action = #selector(clicked)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func clicked() { run() }
}

/// The list's document view: rows from the top.
private final class AutomationsFlippedView: NSView {
    override var isFlipped: Bool { true }
}
