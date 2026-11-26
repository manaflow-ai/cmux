import SwiftUI
import CmuxNextDesign

/// The New and Edit form, in the detail pane where the automation shows (no sheet): name, what it
/// does, when, where, and a time limit. Problems show under their field once the person tried to
/// save; the CLI's refusal shows above the buttons. Return in a one-line field saves, Cmd+Return
/// saves from the task text, Escape cancels, and Save says when it runs so it never fires twice.
struct AutomationFormView: View {
    @Bindable var page: AutomationsPage
    let palette: AutomationsPalette
    let strings: AutomationStrings
    @State private var tried = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        if let draft = page.draft {
            let binding = Binding<AutomationDraft>(get: { page.draft ?? draft }, set: { page.draft = $0 })
            let problems = tried ? Set(draft.problems) : []
            VStack(alignment: .leading, spacing: 14) {
                Text(draft.editing == nil ? strings.formNewTitle : strings.formEditTitle)
                    .font(palette.header).foregroundStyle(palette.text)

                field(strings.formName, problem: problems.contains(.nameMissing) ? strings.problemName : nil) {
                    TextField(strings.formName, text: binding.name).labelsHidden().textFieldStyle(.roundedBorder)
                        .focusEffectDisabled().focused($nameFocused).onSubmit(save)
                }

                field(strings.formWhatToDo, problem: problems.contains(.taskMissing) ? strings.problemTask : nil) {
                    VStack(alignment: .leading, spacing: 6) {
                        Picker(strings.formWhatToDo, selection: binding.isCommand) {
                            Text(strings.formPrompt).tag(false)
                            Text(strings.formCommand).tag(true)
                        }
                        .labelsHidden().pickerStyle(.segmented).fixedSize()
                        TextEditor(text: binding.task)
                            .font(draft.isCommand ? Font(Typography.system(.monospaced, size: TypeScale.body)) : palette.body)
                            .scrollContentBackground(.hidden)
                            .padding(6).frame(minHeight: 72, maxHeight: 160)
                            .background(RoundedRectangle(cornerRadius: Metrics.insetCornerRadius).fill(palette.card))
                            .overlay(RoundedRectangle(cornerRadius: Metrics.insetCornerRadius).stroke(palette.separator))
                            .onKeyPress(.return, phases: .down) { press in
                                guard press.modifiers.contains(.command) else { return .ignored }
                                save()
                                return .handled
                            }
                    }
                }

                field(strings.formWhen, problem: problems.contains(.intervalTooShort) ? strings.problemInterval
                      : problems.contains(.cronMissing) ? strings.problemCron : nil) {
                    ScheduleEditor(schedule: binding.schedule, strings: strings, palette: palette)
                }

                field(strings.formWhere, problem: nil) {
                    Picker(strings.formWhere, selection: binding.cloud) {
                        Text(strings.target(.thisMac)).tag(false)
                        Text(strings.target(.cloud)).tag(true)
                    }
                    .labelsHidden().pickerStyle(.segmented).fixedSize()
                    .disabled(draft.editing != nil)
                }

                if !draft.cloud || draft.isCommand {
                    HStack(alignment: .top, spacing: 16) {
                        field(strings.formFolder, problem: nil) {
                            TextField(strings.formFolderPlaceholder, text: binding.folder).labelsHidden()
                                .textFieldStyle(.roundedBorder).focusEffectDisabled().frame(minWidth: 220).onSubmit(save)
                        }
                        field(strings.formTimeout, problem: nil) {
                            Stepper(value: binding.timeoutMinutes, in: 1...1440) {
                                Text("\(draft.timeoutMinutes)").font(palette.body).monospacedDigit()
                            }
                            .fixedSize()
                        }
                    }
                }

                if let error = page.actionError {
                    Text(error).font(palette.caption).foregroundStyle(palette.danger).textSelection(.enabled)
                }
                HStack(spacing: 8) {
                    Button(page.saving ? strings.formSaving : (draft.editing == nil ? strings.formCreate : strings.formSave), action: save)
                        .buttonStyle(.borderedProminent).disabled(page.saving)
                    CmuxDialogActionButton(strings.cancel, hint: .escape) { page.actionError = nil; page.draft = nil }
                }
                .controlSize(.small)
            }
            .padding(16)
            .onAppear { nameFocused = draft.editing == nil }
        }
    }

    private func save() {
        tried = true
        guard page.draft?.problems.isEmpty == true else { return }
        Task { await page.save() }
    }

    private func field<Content: View>(_ label: String, problem: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(palette.caption).foregroundStyle(palette.secondary)
            content()
            if let problem {
                Text(problem).font(palette.caption).foregroundStyle(palette.danger)
            }
        }
    }
}

/// The When field: a preset picker, then the one or two controls that preset needs.
private struct ScheduleEditor: View {
    @Binding var schedule: AutomationDraft.Schedule
    let strings: AutomationStrings
    let palette: AutomationsPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker(strings.formWhen, selection: kind) {
                if schedule == .unchanged { Text(strings.scheduleUnchanged).tag(AutomationDraft.Schedule.Kind?.none) }
                ForEach(AutomationDraft.Schedule.Kind.allCases, id: \.self) { kind in
                    Text(strings.scheduleKind(kind)).tag(Optional(kind))
                }
            }
            .labelsHidden().fixedSize()
            switch schedule {
            case let .every(minutes):
                Stepper(value: Binding(get: { minutes }, set: { schedule = .every(minutes: max(1, $0)) }), in: 1...1440) {
                    Text(strings.everyMinutes(minutes)).font(palette.body).monospacedDigit()
                }
                .fixedSize()
            case let .daily(h, m):
                clock(h, m) { schedule = .daily(hour: $0, minute: $1) }
            case let .weekdays(h, m):
                clock(h, m) { schedule = .weekdays(hour: $0, minute: $1) }
            case let .weekly(day, h, m):
                HStack(spacing: 8) {
                    Picker(strings.formWhen, selection: Binding(get: { day }, set: { schedule = .weekly(weekday: $0, hour: h, minute: m) })) {
                        ForEach(0..<7, id: \.self) { d in Text(Calendar.current.weekdaySymbols[d]).tag(d) }
                    }
                    .labelsHidden().fixedSize()
                    clock(h, m) { schedule = .weekly(weekday: day, hour: $0, minute: $1) }
                }
            case let .cron(expr):
                TextField("0 9 * * 1-5", text: Binding(get: { expr }, set: { schedule = .cron($0) }))
                    .labelsHidden().textFieldStyle(.roundedBorder).focusEffectDisabled()
                    .font(Font(Typography.system(.monospaced, size: TypeScale.body))).frame(width: 200)
                Text(strings.cronHelp).font(palette.caption).foregroundStyle(palette.tertiary)
            case .manual, .hourly, .unchanged:
                EmptyView()
            }
        }
    }

    private var kind: Binding<AutomationDraft.Schedule.Kind?> {
        Binding(get: { schedule.kind }, set: { next in
            guard let next, next != schedule.kind else { return }
            schedule = switch next {
            case .manual: .manual
            case .every: .every(minutes: 30)
            case .hourly: .hourly
            case .daily: .daily(hour: 9, minute: 0)
            case .weekdays: .weekdays(hour: 9, minute: 0)
            case .weekly: .weekly(weekday: 1, hour: 9, minute: 0)
            case .cron: .cron("0 9 * * 1-5")
            }
        })
    }

    private func clock(_ hour: Int, _ minute: Int, set: @escaping (Int, Int) -> Void) -> some View {
        let date = Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: .now) ?? .now
        return DatePicker(strings.formWhen, selection: Binding(get: { date }, set: { d in
            let c = Calendar.current.dateComponents([.hour, .minute], from: d)
            set(c.hour ?? hour, c.minute ?? minute)
        }), displayedComponents: .hourAndMinute)
        .labelsHidden().fixedSize()
    }
}
