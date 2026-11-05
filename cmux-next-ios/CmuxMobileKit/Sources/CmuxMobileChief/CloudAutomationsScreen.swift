#if os(iOS)
import CmuxMobileDesign
import SwiftUI

private let theme = CmuxMobileTheme.standard

/// Settings → Automations (the Mac's Automations page, its Cloud automations): Needs you, Today,
/// Later and Paused, each row's schedule and next run; a tap pushes its detail (Run now, Pause or
/// Resume, Delete, History). Swipe a row to pause or delete it.
public struct CloudAutomationsScreen: View {
    @State private var model: CloudAutomationsModel
    @State private var deleting: CloudAutomation?

    public init(model: CloudAutomationsModel = .live()) {
        _model = State(initialValue: model)
    }

    public var body: some View {
        content
            .navigationTitle("Automations")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await model.load() }
            .task { await model.load() }
            .modifier(CloudAutomationAlerts(model: model, deleting: $deleting, showsFailure: !model.showsDetail))
            .background(theme.colors.bgGrouped.color.ignoresSafeArea())
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView("Loading automations…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("automations.loading")
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't load automations", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { Task { await model.load() } }.buttonStyle(.borderedProminent)
            }
            .accessibilityIdentifier("automations.failed")
        case .loaded:
            list
        }
    }

    private var list: some View {
        let sections = model.sections(now: .now)
        return List {
            ForEach(sections, id: \.0) { section, rows in
                Section(section.title) {
                    ForEach(rows) { row in
                        // A view link: Settings' stack path holds only its own routes.
                        NavigationLink {
                            CloudAutomationDetail(model: model, id: row.id)
                        } label: {
                            CloudAutomationRow(row: row, busy: model.busyID == row.id)
                        }
                        .contextMenu { CloudAutomationActions(model: model, row: row, deleting: $deleting) }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button("Delete", systemImage: "trash", role: .destructive) { deleting = row }
                                .disabled(!model.canAct)
                            Button(row.enabled ? "Pause" : "Resume", systemImage: row.enabled ? "pause" : "play") {
                                Task { await model.setEnabled(row, !row.enabled) }
                            }
                            .tint(.orange)
                            .disabled(!model.canAct)
                        }
                        .accessibilityIdentifier("automations.row.\(row.id)")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .overlay {
            if sections.isEmpty {
                ContentUnavailableView("No Automations", systemImage: "clock.badge.checkmark",
                                       description: Text("Ask your Chief (\"every weekday at 9, summarize my PRs\") to make one."))
                    .accessibilityIdentifier("automations.empty")
            }
        }
        .accessibilityIdentifier("automations.list")
    }
}

/// One automation: its name, schedule and next run, and how its last run ended.
struct CloudAutomationRow: View {
    let row: CloudAutomation
    let busy: Bool

    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(automationColor(row.last)).frame(width: 8, height: 8).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name).font(theme.type.rowTitle).foregroundStyle(theme.colors.label)
                Text(subtitle).font(theme.type.meta).foregroundStyle(theme.colors.label2)
            }
            Spacer(minLength: 8)
            if busy { ProgressView() }
        }
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        var parts = [row.schedule]
        if !row.enabled { parts.append(String(localized: "Paused")) }
        if row.needsYou { parts.append(String(localized: "Last run failed")) }
        if row.enabled, let next = row.nextRun {
            parts.append(String(localized: "next \(next.formatted(.relative(presentation: .named)))"))
        }
        return parts.joined(separator: " · ")
    }
}

func automationColor(_ result: CloudAutomation.LastResult) -> Color {
    switch result {
    case .succeeded: .green
    case .failed: .red
    case .running: .blue
    case .skipped: .orange
    case .none: Color(uiColor: .tertiaryLabel)
    }
}

/// Run now, Pause or Resume and Delete: the row's menu and the detail's buttons.
struct CloudAutomationActions: View {
    let model: CloudAutomationsModel
    let row: CloudAutomation
    @Binding var deleting: CloudAutomation?

    var body: some View {
        Group {
            buttons
        }
        .disabled(!model.canAct)
    }

    @ViewBuilder private var buttons: some View {
        Button("Run Now", systemImage: "play.circle") { Task { await model.runNow(row) } }
            .accessibilityIdentifier("automations.run")
        Button(row.enabled ? "Pause" : "Resume", systemImage: row.enabled ? "pause.circle" : "play") {
            Task { await model.setEnabled(row, !row.enabled) }
        }
        .accessibilityIdentifier("automations.toggle")
        Button("Delete", systemImage: "trash", role: .destructive) { deleting = row }
            .accessibilityIdentifier("automations.delete")
    }
}

/// The page's questions and notes: Delete's confirmation, a refusal, a run that started.
struct CloudAutomationAlerts: ViewModifier {
    let model: CloudAutomationsModel
    @Binding var deleting: CloudAutomation?
    /// Whether this view shows a refusal (one presenter at a time: the list, or the pushed page).
    var showsFailure = true
    var deleted: (() -> Void)?

    func body(content: Content) -> some View {
        content
            .confirmationDialog(deleting.map { "Delete \($0.name)?" } ?? "",
                                isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                                titleVisibility: .visible, presenting: deleting) { row in
                Button("Delete Automation", role: .destructive) {
                    deleted?()
                    Task { await model.delete(row) }
                }
                .accessibilityIdentifier("automations.delete.confirm")
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("It stops running. Its run history stays.")
            }
            .alert("Couldn't do that", isPresented: Binding(get: { showsFailure && model.failure != nil }, set: { if !$0 { model.failure = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.failure ?? "")
            }
    }
}

/// One automation's page: what it does, its schedule, Run now, Pause or Resume, Delete, and its
/// last runs (the Mac's detail pane and History).
struct CloudAutomationDetail: View {
    let model: CloudAutomationsModel
    let id: String
    @State private var deleting: CloudAutomation?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let row = model.automation(id) {
                List {
                    Section {
                        LabeledContent("Schedule", value: row.schedule)
                        LabeledContent("Status", value: row.enabled ? String(localized: "On") : String(localized: "Paused"))
                        if row.enabled, let next = row.nextRun {
                            LabeledContent("Next run", value: next.formatted(date: .abbreviated, time: .shortened))
                        }
                    }
                    if !row.task.isEmpty {
                        Section("Does") { Text(row.task).font(theme.type.body).textSelection(.enabled) }
                    }
                    Section {
                        CloudAutomationActions(model: model, row: row, deleting: $deleting)
                    } footer: {
                        if model.startedID == row.id {
                            Text("\(row.name) is running.").accessibilityIdentifier("automations.started")
                        }
                    }
                    Section("History") {
                        if row.runs.isEmpty {
                            Text("No runs yet.").foregroundStyle(theme.colors.label2)
                        }
                        ForEach(row.runs.prefix(20)) { run in
                            HStack(spacing: 10) {
                                Circle().fill(automationColor(run.result)).frame(width: 7, height: 7).accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(run.at.formatted(date: .abbreviated, time: .shortened)).font(theme.type.rowTitle)
                                    Text([run.result.rawValue, run.trigger, run.reason].compactMap(\.self).joined(separator: " · "))
                                        .font(theme.type.meta).foregroundStyle(theme.colors.label2)
                                }
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .navigationTitle(row.name)
            } else {
                ContentUnavailableView("Automation deleted", systemImage: "trash")
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .modifier(CloudAutomationAlerts(model: model, deleting: $deleting, showsFailure: model.showsDetail, deleted: { dismiss() }))
        .onAppear { model.showsDetail = true }
        .onDisappear { model.showsDetail = false }
        .accessibilityIdentifier("automations.detail")
    }
}
#endif
