#if os(iOS)
import CmuxMobileDesign
import CmuxSpinner
import SwiftUI

private let theme = CmuxMobileTheme.standard

/// Settings → Cloud → Cloud Machines (the Mac's Machines section, its Cloud machines): the
/// plan's use, each machine's state and cost; a tap pushes its page (Start or Pause, Rename, Idle
/// Pause, Keep, Grow, Snapshots, Archive and Delete, Delete). **+** makes a new machine; archives
/// of deleted machines restore as new ones.
public struct CloudMachinesScreen: View {
    @State private var model: CloudMachinesModel
    @State private var creating = false
    /// Opens the Cloud chats through a paired Mac (the shell's Cloud Chats sheet); nil hides it.
    private let openChats: (() -> Void)?

    public init(model: CloudMachinesModel = .live(), openChats: (() -> Void)? = nil) {
        _model = State(initialValue: model)
        self.openChats = openChats
    }

    public var body: some View {
        content
            .navigationTitle("Cloud Machines")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("New Cloud Machine", systemImage: "plus") { creating = true }
                        .disabled(!model.canAct)
                        .accessibilityIdentifier("cloudMachines.new")
                }
            }
            .refreshable { await model.load() }
            .task { await model.load() }
            .sheet(isPresented: $creating) { NewCloudMachineSheet(model: model) }
            .modifier(CloudMachineAlerts(model: model, showsFailure: !model.showsDetail))
            .background(theme.colors.bgGrouped.color.ignoresSafeArea())
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .loading:
            CmuxSpinner(label: Text("Loading Cloud machines…"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("cloudMachines.loading")
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't load Cloud machines", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { Task { await model.load() } }.buttonStyle(.borderedProminent)
            }
            .accessibilityIdentifier("cloudMachines.failed")
        case .loaded:
            list
        }
    }

    private var list: some View {
        List {
            if let plan = model.plan {
                Section {
                    LabeledContent("Plan", value: plan.planID.capitalized)
                    LabeledContent("Running", value: "\(plan.active) of \(plan.maxActive)")
                    LabeledContent("Saved", value: "\(plan.saved) of \(plan.maxSaved)")
                    if let used = plan.hoursUsed {
                        LabeledContent("Machine hours", value: plan.hoursIncluded.map { "\(used.formatted(.number.precision(.fractionLength(0...1)))) of \($0.formatted())" }
                            ?? used.formatted(.number.precision(.fractionLength(0...1))))
                    }
                }
                .accessibilityIdentifier("cloudMachines.plan")
            }
            if !model.machines.isEmpty {
                Section("Machines") {
                    ForEach(model.sorted) { machine in
                        NavigationLink {
                            CloudMachineDetail(model: model, id: machine.id, openChats: openChats)
                        } label: {
                            CloudMachineRow(machine: machine, busy: model.busyID == machine.id)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if machine.status == .running {
                                Button("Pause", systemImage: "pause") { Task { await model.pause(machine) } }.tint(.orange).disabled(!model.canAct)
                            } else if machine.status == .paused {
                                Button("Start", systemImage: "play") { Task { await model.start(machine) } }.tint(.green).disabled(!model.canAct)
                            }
                        }
                        .accessibilityIdentifier("cloudMachines.row.\(machine.id)")
                    }
                }
            }
            if !model.archives.isEmpty {
                Section {
                    ForEach(model.archives) { archive in
                        CloudSnapshotRow(model: model, snapshot: archive)
                    }
                } header: {
                    Text("Archives")
                } footer: {
                    Text("A deleted machine's disk, kept for a while. Restore makes a new machine from it.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .overlay {
            if model.machines.isEmpty && model.archives.isEmpty {
                ContentUnavailableView {
                    Label("No Cloud Machines", systemImage: "cloud")
                } description: {
                    Text("A Cloud machine runs your agents while your Mac sleeps.")
                } actions: {
                    Button("New Cloud Machine") { creating = true }.buttonStyle(.borderedProminent).disabled(!model.canAct)
                }
                .accessibilityIdentifier("cloudMachines.empty")
            }
        }
        .accessibilityIdentifier("cloudMachines.list")
    }
}

/// One machine: its name, state, size and cost.
struct CloudMachineRow: View {
    let machine: CloudMachine
    let busy: Bool

    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(cloudMachineColor(machine.status)).frame(width: 8, height: 8).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(machine.title).font(theme.type.rowTitle).foregroundStyle(theme.colors.label)
                Text(subtitle).font(theme.type.meta).foregroundStyle(theme.colors.label2)
            }
            Spacer(minLength: 8)
            if busy || machine.status.isTransition { CmuxSpinner() }
        }
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        [cloudMachineStatusTitle(machine.status), machine.size.summary, machine.cost(now: .now)]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

func cloudMachineColor(_ status: CloudMachine.Status) -> Color {
    switch status {
    case .running: .green
    case .starting, .provisioning: .blue
    case .pausing, .paused: .orange
    case .failed: .red
    case .deleting: Color(uiColor: .tertiaryLabel)
    }
}

func cloudMachineStatusTitle(_ status: CloudMachine.Status) -> String {
    switch status {
    case .provisioning: String(localized: "Setting up")
    case .starting: String(localized: "Starting")
    case .running: String(localized: "Running")
    case .pausing: String(localized: "Pausing")
    case .paused: String(localized: "Paused")
    case .deleting: String(localized: "Deleting")
    case .failed: String(localized: "Failed")
    }
}

func idlePauseTitle(_ minutes: Int) -> String {
    switch minutes {
    case 0: String(localized: "Off")
    case 60: String(localized: "1 hour")
    case 120: String(localized: "2 hours")
    default: String(localized: "\(minutes) minutes")
    }
}

/// A snapshot or archive: its name, size and date; Restore as a new machine, or Delete.
struct CloudSnapshotRow: View {
    let model: CloudMachinesModel
    let snapshot: CloudMachineSnapshot
    @State private var deleting = false

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot.title).font(theme.type.rowTitle)
                Text(detail).font(theme.type.meta).foregroundStyle(theme.colors.label2)
            }
            Spacer(minLength: 8)
            if model.busyID == snapshot.id || snapshot.status == "creating" { CmuxSpinner() }
        }
        .accessibilityElement(children: .combine)
        .contextMenu { buttons }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) { buttons }
        .confirmationDialog("Delete \(snapshot.title)?", isPresented: $deleting, titleVisibility: .visible) {
            Button("Delete Snapshot", role: .destructive) { Task { await model.deleteSnapshot(snapshot) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It can't be restored after this.")
        }
        .accessibilityIdentifier("cloudMachines.snapshot.\(snapshot.id)")
    }

    @ViewBuilder private var buttons: some View {
        Button("Restore as New Machine", systemImage: "arrow.counterclockwise") { Task { await model.restore(snapshot) } }
            .disabled(!model.canAct || !snapshot.ready)
        Button("Delete", systemImage: "trash", role: .destructive) { deleting = true }
            .disabled(!model.canAct)
    }

    private var detail: String {
        var parts = [CloudMachine.Size.gigabytes(snapshot.sizeMB)]
        if let at = snapshot.createdAt { parts.append(at.formatted(date: .abbreviated, time: .shortened)) }
        if let until = snapshot.archiveUntil { parts.append(String(localized: "kept until \(until.formatted(date: .abbreviated, time: .omitted))")) }
        if !snapshot.ready { parts.append(snapshot.status.capitalized) }
        return parts.joined(separator: " · ")
    }
}

/// The page's refusal alert and approval note.
struct CloudMachineAlerts: ViewModifier {
    let model: CloudMachinesModel
    var showsFailure = true

    func body(content: Content) -> some View {
        content
            .alert("Couldn't do that", isPresented: Binding(get: { showsFailure && model.failure != nil }, set: { if !$0 { model.failure = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.failure ?? "")
            }
            .alert("Waiting for approval", isPresented: Binding(get: { showsFailure && model.notice != nil }, set: { if !$0 { model.notice = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.notice ?? "")
            }
    }
}

/// New Cloud Machine: a name and a memory size the plan allows (the Mac's New Cloud Machine sheet).
struct NewCloudMachineSheet: View {
    let model: CloudMachinesModel
    @State private var name = ""
    @State private var memoryMB: Int?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name (optional)", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("cloudMachines.new.name")
                }
                Section {
                    Picker("Memory", selection: Binding(get: { memoryMB ?? choices.first ?? 4096 }, set: { memoryMB = $0 })) {
                        ForEach(choices, id: \.self) { mb in Text(CloudMachine.Size.gigabytes(mb)).tag(mb) }
                    }
                } footer: {
                    Text("2 vCPU and a 16 GB disk. You pay while it runs; it pauses when idle.")
                }
            }
            .navigationTitle("New Cloud Machine")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        let size = memoryMB ?? choices.first
                        dismiss()
                        Task { await model.create(name: name, memoryMB: size) }
                    }
                    .disabled(!model.canAct)
                    .accessibilityIdentifier("cloudMachines.new.create")
                }
            }
        }
        .presentationDetents([.medium])
    }

    private var choices: [Int] { model.plan?.memoryChoicesMB ?? [CloudMachine.Size.newMachine.memoryMB ?? 4096] }
}

/// One machine's page: its state and cost, then every action the Mac has for it.
struct CloudMachineDetail: View {
    let model: CloudMachinesModel
    let id: String
    var openChats: (() -> Void)?
    @State private var renaming = false
    @State private var newName = ""
    @State private var snapshotting = false
    @State private var snapshotName = ""
    @State private var deleting = false
    @State private var archiving = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let machine = model.machine(id) {
                List {
                    Section {
                        LabeledContent("Status", value: cloudMachineStatusTitle(machine.status))
                        LabeledContent("Size", value: machine.size.summary)
                        if let cost = machine.cost(now: .now) { LabeledContent("Cost", value: cost) }
                        if let active = machine.lastActiveAt {
                            LabeledContent("Last active", value: active.formatted(.relative(presentation: .named)))
                        }
                        if let evict = machine.evictAt, !machine.keep {
                            LabeledContent("Deleted automatically", value: evict.formatted(date: .abbreviated, time: .omitted))
                        }
                    } footer: {
                        if let note = machine.note { Text(note) }
                    }
                    Section {
                        powerButton(machine)
                        Button("Rename…", systemImage: "pencil") {
                            newName = machine.name ?? ""
                            renaming = true
                        }
                        .accessibilityIdentifier("cloudMachines.rename")
                    }
                    .disabled(!model.canAct)
                    if let openChats, machine.status == .running {
                        Section {
                            Button("Agent Chats", systemImage: "bubble.left.and.bubble.right") { openChats() }
                                .accessibilityIdentifier("cloudMachines.chats")
                        } footer: {
                            Text("Open and start agent chats on it through your Mac.")
                        }
                    }
                    Section {
                        Picker(selection: Binding(get: { machine.idlePauseMinutes }, set: { minutes in Task { await model.setIdlePause(machine, minutes: minutes) } })) {
                            ForEach(Self.idleChoices(machine), id: \.self) { Text(idlePauseTitle($0)).tag($0) }
                        } label: {
                            Label("Pause When Idle", systemImage: "moon.zzz")
                        }
                        .accessibilityIdentifier("cloudMachines.idle")
                        Toggle(isOn: Binding(get: { machine.keep }, set: { keep in Task { await model.setKeep(machine, keep) } })) {
                            Label("Keep", systemImage: "pin")
                        }
                        .accessibilityIdentifier("cloudMachines.keep")
                        if !growChoices(machine).isEmpty {
                            Menu {
                                ForEach(growChoices(machine), id: \.self) { mb in
                                    Button(CloudMachine.Size.gigabytes(mb)) { Task { await model.grow(machine, memoryMB: mb) } }
                                }
                            } label: {
                                Label("Grow Memory", systemImage: "arrow.up.right.square")
                            }
                            .accessibilityIdentifier("cloudMachines.grow")
                        }
                    } footer: {
                        Text("Keep stops cmux from deleting it automatically. A machine can grow but not shrink.")
                    }
                    .disabled(!model.canAct || machine.status.isTransition)
                    Section {
                        ForEach(model.snapshots(of: machine.id)) { CloudSnapshotRow(model: model, snapshot: $0) }
                        Button("Take Snapshot…", systemImage: "camera") {
                            snapshotName = ""
                            snapshotting = true
                        }
                        .disabled(!model.canAct || !(machine.status == .running || machine.status == .paused))
                        .accessibilityIdentifier("cloudMachines.snapshot")
                    } header: {
                        Text("Snapshots")
                    }
                    Section {
                        if machine.status == .paused || machine.status == .failed {
                            Button("Archive and Delete…", systemImage: "archivebox", role: .destructive) { archiving = true }
                                .accessibilityIdentifier("cloudMachines.archive")
                        }
                        Button("Delete Machine…", systemImage: "trash", role: .destructive) { deleting = true }
                            .accessibilityIdentifier("cloudMachines.delete")
                    }
                    .disabled(!model.canAct || machine.status == .deleting)
                }
                .listStyle(.insetGrouped)
                .navigationTitle(machine.title)
                .alert("Rename Machine", isPresented: $renaming) {
                    TextField("Name", text: $newName)
                    Button("Rename") { Task { await model.rename(machine, to: newName) } }
                    Button("Cancel", role: .cancel) {}
                }
                .alert("Take Snapshot", isPresented: $snapshotting) {
                    TextField("Name (optional)", text: $snapshotName)
                    Button("Take Snapshot") { Task { await model.takeSnapshot(machine, name: snapshotName) } }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Saves the machine's disk so you can restore it as a new machine.")
                }
                .confirmationDialog("Delete \(machine.title)?", isPresented: $deleting, titleVisibility: .visible) {
                    Button("Delete Machine", role: .destructive) {
                        dismiss()
                        Task { await model.delete(machine) }
                    }
                    .accessibilityIdentifier("cloudMachines.delete.confirm")
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Its disk and everything on it are gone for good.")
                }
                .confirmationDialog("Archive and delete \(machine.title)?", isPresented: $archiving, titleVisibility: .visible) {
                    Button("Archive and Delete", role: .destructive) {
                        dismiss()
                        Task { await model.archiveAndDelete(machine) }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("cmux keeps its disk as an archive you can restore for a while, then deletes the machine.")
                }
            } else {
                ContentUnavailableView("Machine deleted", systemImage: "trash")
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .modifier(CloudMachineAlerts(model: model, showsFailure: model.showsDetail))
        .onAppear { model.showsDetail = true }
        .onDisappear { model.showsDetail = false }
        .accessibilityIdentifier("cloudMachines.detail")
    }

    @ViewBuilder private func powerButton(_ machine: CloudMachine) -> some View {
        switch machine.status {
        case .running:
            Button("Pause", systemImage: "pause.circle") { Task { await model.pause(machine) } }
                .accessibilityIdentifier("cloudMachines.pause")
        case .paused:
            Button("Start", systemImage: "play.circle") { Task { await model.start(machine) } }
                .accessibilityIdentifier("cloudMachines.start")
        default:
            Label(cloudMachineStatusTitle(machine.status), systemImage: "hourglass").foregroundStyle(theme.colors.label2)
        }
    }

    static func idleChoices(_ machine: CloudMachine) -> [Int] {
        Array(Set(CloudMachine.idlePauseChoices + [machine.idlePauseMinutes])).sorted()
    }

    private func growChoices(_ machine: CloudMachine) -> [Int] {
        let current = machine.size.memoryMB ?? 0
        return (model.plan?.memoryChoicesMB ?? []).filter { $0 > current }
    }
}
#endif
