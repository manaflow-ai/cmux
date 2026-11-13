#if os(iOS)
import CmuxMobileDesign
import CmuxMobileModel
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
    /// Each machine's workspaces on its page (live: the Workspaces list's own); nil hides them.
    private let workspaces: CloudMachineWorkspaces?

    /// Opens a machine's page as a route on the host's navigation path (nil: the page pushes it
    /// itself). On a value path every page must be a value too, or a pop skips levels.
    private let openMachine: ((String) -> Void)?

    public init(model: CloudMachinesModel = .live(), openChats: (() -> Void)? = nil, workspaces: CloudMachineWorkspaces? = nil,
                openMachine: ((String) -> Void)? = nil) {
        _model = State(initialValue: model)
        self.openChats = openChats
        self.workspaces = workspaces
        self.openMachine = openMachine
    }

    /// One machine's page, for a host that pushes it as a route (``openMachine``).
    public static func machinePage(model: CloudMachinesModel, id: String, openChats: (() -> Void)?,
                                   workspaces: CloudMachineWorkspaces?) -> some View {
        CloudMachineDetail(model: model, id: id, openChats: openChats, workspaces: workspaces)
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

    /// A machine's row: a route on the host's path when it has one, else an in-place push.
    @ViewBuilder
    private func machineLink(_ machine: CloudMachine, @ViewBuilder label: () -> some View) -> some View {
        if let openMachine {
            Button { openMachine(machine.id) } label: {
                HStack {
                    label()
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(theme.type.meta.weight(.semibold))
                        .foregroundStyle(theme.colors.label3)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            NavigationLink {
                CloudMachineDetail(model: model, id: machine.id, openChats: openChats, workspaces: workspaces)
            } label: {
                label()
            }
        }
    }

    private var list: some View {
        List {
            if let plan = model.plan {
                Section {
                    LabeledContent("Plan", value: plan.planID.capitalized)
                    LabeledContent("Running", value: CloudMachinePlan.count(plan.active, of: plan.maxActive))
                    LabeledContent("Saved", value: CloudMachinePlan.count(plan.saved, of: plan.maxSaved))
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
                        machineLink(machine) {
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
    var workspaces: CloudMachineWorkspaces?
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
                    if let workspaces {
                        CloudMachineWorkspacesSection(machine: machine, workspaces: workspaces) { workspaces.open($0) }
                    }
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

/// A Cloud machine's workspaces where its page lists them: what each workspace row opens, and
/// New Workspace on it (instant: the new workspace opens at once). The shell gives the live
/// list's own (the same workspaces the Workspaces list shows for the machine).
public struct CloudMachineWorkspaces {
    public enum State: Equatable, Sendable {
        /// The machine's daemon has not listed its workspaces yet.
        case loading
        case loaded([Workspace])
        /// It could not be reached (why).
        case failed(String)
    }

    public var state: @MainActor (_ machineID: String) -> State
    public var canCreate: @MainActor (_ machineID: String) -> Bool
    public var create: @MainActor (_ machineID: String) -> Workspace?
    public var page: @MainActor (Workspace) -> AnyView
    /// The page is on screen: its machine's link opens (and stays while recent).
    public var shown: @MainActor (_ machineID: String) -> Void
    /// Opens a workspace of the machine: the shell pushes it as a route on its navigation path, so
    /// the path itself says what is on screen (the tab bar, the machine's link).
    public var open: @MainActor (Workspace) -> Void

    public init(state: @escaping @MainActor (String) -> State, canCreate: @escaping @MainActor (String) -> Bool,
                create: @escaping @MainActor (String) -> Workspace?, page: @escaping @MainActor (Workspace) -> AnyView,
                shown: @escaping @MainActor (String) -> Void = { _ in },
                open: @escaping @MainActor (Workspace) -> Void = { _ in }) {
        self.state = state
        self.canCreate = canCreate
        self.create = create
        self.page = page
        self.shown = shown
        self.open = open
    }
}

/// Workspaces on a machine's page: each pushes its workspace; New Workspace makes one and opens it.
struct CloudMachineWorkspacesSection: View {
    /// Why the section lists nothing while the machine is not running.
    static func notRunning(_ machine: CloudMachine) -> String {
        switch machine.status {
        case .paused: String(localized: "Start \(machine.title) to open its workspaces.")
        case .starting, .provisioning: String(localized: "Waking up… Its workspaces open once it runs.")
        case .pausing: String(localized: "Pausing.")
        case .failed: String(localized: "\(machine.title) didn't start. Start it again to open its workspaces.")
        case .deleting: String(localized: "Being deleted.")
        case .running: ""
        }
    }

    let machine: CloudMachine
    let workspaces: CloudMachineWorkspaces
    /// Pushes a workspace made here (the page's own destination).
    let open: (Workspace) -> Void

    var body: some View {
        Section {
            if machine.status != .running {
                Text(Self.notRunning(machine))
                    .font(theme.type.rowSubtitle)
                    .foregroundStyle(theme.colors.label2)
                    .accessibilityIdentifier("cloudMachines.workspaces.stopped")
            } else {
                switch workspaces.state(machine.id) {
                case .loading:
                    HStack(spacing: 10) {
                        CmuxSpinner().controlSize(.mini)
                        Text("Loading workspaces…").font(theme.type.rowSubtitle).foregroundStyle(theme.colors.label2)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("cloudMachines.workspaces.loading")
                case .failed(let reason):
                    Text(reason)
                        .font(theme.type.rowSubtitle)
                        .foregroundStyle(theme.colors.label2)
                        .accessibilityIdentifier("cloudMachines.workspaces.failed")
                case .loaded(let list):
                    if list.isEmpty {
                        Text("No workspaces yet.")
                            .font(theme.type.rowSubtitle)
                            .foregroundStyle(theme.colors.label2)
                            .accessibilityIdentifier("cloudMachines.workspaces.empty")
                    }
                    ForEach(list) { workspace in
                        Button {
                            open(workspace)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(workspace.title).font(theme.type.rowTitle).foregroundStyle(theme.colors.label)
                                    if let place = workspace.branch ?? (workspace.directory.isEmpty ? nil : workspace.directory) {
                                        Text(place).font(theme.type.meta).foregroundStyle(theme.colors.label2)
                                    }
                                }
                                Spacer(minLength: 8)
                                // A push, as a navigation row's (the button opens a route on the stack).
                                Image(systemName: "chevron.right")
                                    .font(theme.type.meta.weight(.semibold))
                                    .foregroundStyle(theme.colors.label3)
                                    .accessibilityHidden(true)
                            }
                            .contentShape(Rectangle())
                            .accessibilityElement(children: .combine)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(.isButton)
                        .accessibilityIdentifier("cloudMachines.workspace.\(workspace.id)")
                    }
                }
                Button("New Workspace", systemImage: "plus.rectangle.on.rectangle") {
                    if let created = workspaces.create(machine.id) { open(created) }
                }
                .disabled(!workspaces.canCreate(machine.id))
                .accessibilityIdentifier("cloudMachines.workspaces.new")
            }
        } header: {
            Text("Workspaces")
        }
        .onAppear { workspaces.shown(machine.id) }
    }
}
#endif
