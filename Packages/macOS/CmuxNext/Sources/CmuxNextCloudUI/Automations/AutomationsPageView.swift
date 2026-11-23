public import SwiftUI
import CmuxNextDesign

/// The Automations page (docs/automations-platonic-ideal.md section 8, option A;
/// docs/automations-desktop-parity.md): a list grouped Needs you / Today / Later / Paused on the
/// left, the selected automation's detail, buttons and run history on the right, where each run
/// opens as its chat (a prompt run) or its log (a command run). A stopped runner says so at the
/// top. Rows get value snapshots and closures only (the list snapshot rule).
public struct AutomationsPageView: View {
    /// What the page's buttons do. Left out, a button runs the page's own command through its
    /// ``AutomationsPage/cli``; with neither, the button is not shown.
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
        /// Opens a prompt run's agent chat (its session name, a title for it); nil hides Open chat.
        public var openChat: (@MainActor @Sendable (_ session: String, _ title: String) -> Void)?

        public init(new: (@MainActor @Sendable () -> Void)? = nil,
                    runNow: (@MainActor @Sendable (AutomationRow) -> Void)? = nil,
                    setEnabled: (@MainActor @Sendable (AutomationRow, Bool) -> Void)? = nil,
                    edit: (@MainActor @Sendable (AutomationRow) -> Void)? = nil,
                    signIn: (@MainActor @Sendable () -> Void)? = nil,
                    openChat: (@MainActor @Sendable (_ session: String, _ title: String) -> Void)? = nil) {
            self.new = new
            self.runNow = runNow
            self.setEnabled = setEnabled
            self.edit = edit
            self.signIn = signIn
            self.openChat = openChat
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

    private var canAct: Bool { page.cli != nil }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(palette.separator)
            runnerLine
            problemLines
            if let error = page.actionError, page.draft == nil {
                Text(error).font(palette.caption).foregroundStyle(palette.danger).lineLimit(3)
                    .padding(.horizontal, 16).padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading)
            }
            if page.rows.isEmpty && page.draft == nil {
                Text(strings.empty).font(palette.body).foregroundStyle(palette.secondary)
                    .multilineTextAlignment(.center).padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    list.frame(width: 320)
                    Divider().overlay(palette.separator)
                    ScrollView {
                        Group {
                            if page.draft != nil {
                                AutomationFormView(page: page, palette: palette, strings: strings)
                            } else {
                                detail
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    .thinScrollers()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
        }
        .background(palette.background)
        .task(id: page.selection) {
            if let row = page.selected { await page.markSeen(row) }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(strings.title).font(palette.header).foregroundStyle(palette.text)
            AutomationChip(text: strings.active(page.rows.filter(\.enabled).count), palette: palette)
            Spacer()
            if let new = actions.new {
                Button(strings.new) { new() }.buttonStyle(.borderedProminent).controlSize(.small)
            } else if canAct, page.draft == nil {
                Button(strings.new) { page.draft = AutomationDraft() }
                    .buttonStyle(.borderedProminent).controlSize(.small)
            }
        }
        .padding(.horizontal, 16).frame(height: 44)
    }

    /// A runner that does not run says so, with the button that starts it: a schedule that never
    /// fires must never look like "nothing due".
    @ViewBuilder private var runnerLine: some View {
        if let runner = page.runner, runner != .running, page.problems[.thisMac] == nil {
            HStack(spacing: 8) {
                Circle().fill(palette.danger).frame(width: 7, height: 7)
                Text(runner == .stalled ? strings.runnerStalled : strings.runnerStopped)
                    .font(palette.caption).foregroundStyle(palette.text)
                if canAct {
                    Button(runner == .stalled ? strings.runnerRestart : strings.runnerTurnOn) {
                        Task { await page.startRunner() }
                    }
                    .controlSize(.small)
                }
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 6)
            .background(palette.danger.opacity(0.08))
        }
    }

    /// One line per source that did not load, so a failure never reads as "no automations".
    @ViewBuilder private var problemLines: some View {
        ForEach([AutomationRow.Target.thisMac, .cloud], id: \.self) { target in
            if let code = page.problems[target] {
                HStack(spacing: 8) {
                    Text(strings.problem(target, code: code)).font(palette.caption).foregroundStyle(palette.attention)
                    if let signIn = Self.signIn(for: target, code: code, actions: actions) {
                        SignInButtonView { signIn() }.fixedSize()
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// The Sign In a problem line offers: only Cloud's signed-out line, and only when the app gave one.
    static func signIn(for target: AutomationRow.Target, code: String, actions: Actions) -> (@MainActor @Sendable () -> Void)? {
        target == .cloud && code == "automation.signed_out" ? actions.signIn : nil
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(page.sections(now: now), id: \.0) { section, rows in
                    Text(strings.section(section).uppercased()).font(palette.caption).foregroundStyle(palette.tertiary)
                        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 4)
                    ForEach(rows) { row in
                        AutomationListRow(row: row, selected: row.id == page.selection, palette: palette, strings: strings, now: now) {
                            page.draft = nil
                            page.confirmingDelete = nil
                            page.selection = row.id
                        }
                    }
                }
            }
            .thinScrollers()
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
                Text(row.task).font(palette.body).foregroundStyle(palette.text).textSelection(.enabled)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: Metrics.insetCornerRadius).fill(palette.card))
                    .overlay(RoundedRectangle(cornerRadius: Metrics.insetCornerRadius).stroke(palette.separator))
                buttons(row)
                Text(strings.history.uppercased()).font(palette.caption).foregroundStyle(palette.tertiary).padding(.top, 6)
                if row.runs.isEmpty {
                    Text(strings.noRuns).font(palette.caption).foregroundStyle(palette.secondary)
                }
                ForEach(row.runs.prefix(20)) { run in
                    runRow(run, of: row)
                    Divider().overlay(palette.separator)
                }
            }
            .padding(16)
        }
    }

    @ViewBuilder private func buttons(_ row: AutomationRow) -> some View {
        if page.confirmingDelete == row.id {
            HStack(spacing: 6) {
                Text(strings.deleteConfirm).font(palette.caption).foregroundStyle(palette.text)
                CmuxDialogActionButton(strings.delete, hint: .return, role: .destructive) { Task { await page.delete(row) } }
                CmuxDialogActionButton(strings.cancel, hint: .escape) { page.confirmingDelete = nil }
            }
            .controlSize(.small)
        } else if actions.runNow != nil || actions.setEnabled != nil || actions.edit != nil || canAct {
            HStack(spacing: 6) {
                if let runNow = actions.runNow {
                    Button(strings.runNow) { runNow(row) }.buttonStyle(.borderedProminent)
                } else if canAct {
                    Button(strings.runNow) { Task { await page.runNow(row) } }.buttonStyle(.borderedProminent)
                }
                if let setEnabled = actions.setEnabled {
                    Button(row.enabled ? strings.pause : strings.resume) { setEnabled(row, !row.enabled) }
                } else if canAct {
                    Button(row.enabled ? strings.pause : strings.resume) { Task { await page.setEnabled(row, !row.enabled) } }
                }
                if let edit = actions.edit {
                    Button(strings.edit) { edit(row) }
                } else if canAct, row.target == .thisMac { // a Cloud edit changes the name only: delete and make it again
                    Button(strings.edit) { page.actionError = nil; page.draft = AutomationDraft(editing: row) }
                }
                if canAct {
                    Button(strings.delete) { page.confirmingDelete = row.id }
                }
            }
            .controlSize(.small)
        }
    }

    @ViewBuilder private func runRow(_ run: AutomationRow.Run, of row: AutomationRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle().fill(palette.color(run.result)).frame(width: 7, height: 7)
                Text(Self.time(run.at, now: now)).font(palette.caption).foregroundStyle(palette.text)
                    .fontWeight(run.unread ? .semibold : .regular)
                if run.lateSeconds > 120, run.result != .skipped {
                    Text(strings.late(run.lateSeconds / 60)).font(palette.caption).foregroundStyle(palette.attention)
                }
                if run.attempt > 0 {
                    AutomationChip(text: strings.retry(run.attempt), palette: palette)
                }
                if let reason = run.reason {
                    Text(strings.reason(reason)).font(palette.caption)
                        .foregroundStyle(run.result == .failed || run.result == .needsYou ? palette.danger : palette.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if let session = run.session, let openChat = actions.openChat {
                    Button(strings.openChat) { openChat(session, "\(row.name) · \(Self.time(run.at, now: now))") }
                        .buttonStyle(.cmuxPressFill).controlSize(.small)
                }
                if canAct, run.logPath != nil, run.result != .skipped {
                    Button(page.shownLog?.run == run.id ? strings.hideLog : strings.log) { Task { await page.toggleLog(run) } }
                        .buttonStyle(.cmuxPressFill).controlSize(.small)
                }
            }
            if let shown = page.shownLog, shown.run == run.id {
                Text(shown.text.isEmpty ? strings.emptyLog : shown.text)
                    .font(Font(Typography.system(.monospaced, size: TypeScale.caption))).foregroundStyle(palette.text).textSelection(.enabled)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: Metrics.insetCornerRadius).fill(palette.card))
            }
        }
        .padding(.vertical, 3)
    }

    /// `Fri 9:00`, or `9:00` today.
    static func time(_ date: Date, now: Date) -> String {
        let style: Date.FormatStyle = Calendar.current.isDate(date, inSameDayAs: now)
            ? .dateTime.hour().minute()
            : .dateTime.weekday(.abbreviated).hour().minute()
        return date.formatted(style)
    }
}
