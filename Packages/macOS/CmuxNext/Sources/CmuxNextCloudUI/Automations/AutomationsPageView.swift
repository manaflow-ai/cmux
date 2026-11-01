public import SwiftUI

/// The Automations page (docs/automations-platonic-ideal.md section 8, option A): a list grouped
/// Needs you / Today / Later / Paused on the left, the selected automation's detail and run
/// history on the right. Rows get value snapshots and closures only (the list snapshot rule).
public struct AutomationsPageView: View {
    /// What the page's buttons do; the app routes each to the shared automation op.
    public struct Actions: Sendable {
        /// The header's New button; nil hides it (no create form yet).
        public var new: (@MainActor @Sendable () -> Void)?
        public var runNow: @MainActor @Sendable (AutomationRow) -> Void
        public var setEnabled: @MainActor @Sendable (AutomationRow, Bool) -> Void
        public var edit: @MainActor @Sendable (AutomationRow) -> Void

        public init(new: (@MainActor @Sendable () -> Void)? = nil,
                    runNow: @escaping @MainActor @Sendable (AutomationRow) -> Void = { _ in },
                    setEnabled: @escaping @MainActor @Sendable (AutomationRow, Bool) -> Void = { _, _ in },
                    edit: @escaping @MainActor @Sendable (AutomationRow) -> Void = { _ in }) {
            self.new = new
            self.runNow = runNow
            self.setEnabled = setEnabled
            self.edit = edit
        }
    }

    @Bindable private var page: AutomationsPage
    private let palette: AutomationsPalette
    private let actions: Actions
    private let now: Date
    private let strings = AutomationStrings()

    /// Makes the page view.
    ///
    /// - Parameters:
    ///   - page: The model.
    ///   - palette: The hosting window's colors and type.
    ///   - now: The time sections and relative times are drawn for.
    ///   - actions: What the buttons do.
    public init(page: AutomationsPage, palette: AutomationsPalette, now: Date = .now, actions: Actions = Actions()) {
        self.page = page
        self.palette = palette
        self.now = now
        self.actions = actions
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(palette.separator)
            problemLines
            if page.rows.isEmpty {
                Text(strings.empty).font(palette.body).foregroundStyle(palette.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    list.frame(width: 320)
                    Divider().overlay(palette.separator)
                    detail.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
        }
        .background(palette.background)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(strings.title).font(palette.header).foregroundStyle(palette.text)
            AutomationChip(text: strings.active(page.rows.filter(\.enabled).count), palette: palette)
            Spacer()
            if let new = actions.new {
                Button(strings.new) { new() }.buttonStyle(.borderedProminent).controlSize(.small)
            }
        }
        .padding(.horizontal, 16).frame(height: 44)
    }

    /// One line per source that did not load, so a failure never reads as "no automations".
    @ViewBuilder private var problemLines: some View {
        ForEach([AutomationRow.Target.thisMac, .cloud], id: \.self) { target in
            if let code = page.problems[target] {
                Text(strings.problem(target, code: code)).font(palette.caption).foregroundStyle(palette.attention)
                    .padding(.horizontal, 16).padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(page.sections(now: now), id: \.0) { section, rows in
                    Text(strings.section(section).uppercased()).font(palette.caption).foregroundStyle(palette.tertiary)
                        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 4)
                    ForEach(rows) { row in
                        AutomationListRow(row: row, selected: row.id == page.selection, palette: palette, strings: strings, now: now) {
                            page.selection = row.id
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var detail: some View {
        if let row = page.selected {
            VStack(alignment: .leading, spacing: 10) {
                Text(row.name).font(palette.header).foregroundStyle(palette.text)
                HStack(spacing: 6) {
                    Text(row.schedule).font(palette.caption).foregroundStyle(palette.secondary)
                    AutomationChip(text: strings.target(row.target), palette: palette)
                    if let next = row.nextRun, row.enabled {
                        Text(strings.next(Self.time(next, now: now))).font(palette.caption).foregroundStyle(palette.secondary)
                    }
                }
                Text(row.task).font(palette.body).foregroundStyle(palette.text)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(palette.card))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.separator))
                HStack(spacing: 6) {
                    Button(strings.runNow) { actions.runNow(row) }.buttonStyle(.borderedProminent)
                    Button(row.enabled ? strings.pause : strings.resume) { actions.setEnabled(row, !row.enabled) }
                    Button(strings.edit) { actions.edit(row) }
                }
                .controlSize(.small)
                Text(strings.history.uppercased()).font(palette.caption).foregroundStyle(palette.tertiary).padding(.top, 6)
                if row.runs.isEmpty {
                    Text(strings.noRuns).font(palette.caption).foregroundStyle(palette.secondary)
                }
                ForEach(row.runs.prefix(8)) { run in
                    HStack(spacing: 8) {
                        Circle().fill(palette.color(run.result)).frame(width: 7, height: 7)
                        Text(Self.time(run.at, now: now)).font(palette.caption).foregroundStyle(palette.text)
                        if run.lateSeconds > 120 {
                            Text(strings.late(run.lateSeconds / 60)).font(palette.caption).foregroundStyle(palette.attention)
                        }
                        if let reason = run.reason {
                            Text(reason).font(palette.caption).foregroundStyle(palette.secondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 3)
                    Divider().overlay(palette.separator)
                }
            }
            .padding(16)
        }
    }

    /// `Fri 9:00`, or `9:00` today.
    static func time(_ date: Date, now: Date) -> String {
        let style: Date.FormatStyle = Calendar.current.isDate(date, inSameDayAs: now)
            ? .dateTime.hour().minute()
            : .dateTime.weekday(.abbreviated).hour().minute()
        return date.formatted(style)
    }
}
