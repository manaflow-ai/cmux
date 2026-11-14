#if os(iOS)
import CmuxAgentBrands
import CmuxMobileDesign
import CmuxMobileModel
import CmuxSpinner
import PhotosUI
import SwiftUI
import UIKit

private let theme = CmuxMobileTheme.standard

/// New Task, laid out as classic cmux's task composer: a full-screen prompt canvas, and above
/// the keyboard one row of controls (Task Options, attach, the agents and model pills, Start).
/// Drafts sit in the bar; leaving with an unsent task offers to save it there.
///
/// Past classic: several agents at once (one workspace each, each with its model), the Mac's
/// own agents and models, photos sent with the first message, and a refused start that comes
/// back with the Mac's reason. The draft (`WorkspaceCreator.taskDraft`) outlives the screen.
struct TaskComposerScreen: View {
    @Bindable var creator: WorkspaceCreator
    /// The team's same-name Macs, tagged as the filter menu tags them.
    let sameNames: MacNameDisambiguation
    /// Runs after Start with the new placeholders (one: the list opens it).
    let started: ([Workspace]) -> Void
    /// Closes the screen (its cover).
    let close: () -> Void
    @Environment(\.scenePhase) private var scenePhase

    @State private var phase: TaskComposerPhase = .loading
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var choosingPhotos = false
    @State private var loadingPhotos = 0
    @State private var showsOptions = false
    @State private var showsDrafts = false
    @State private var confirmsLeave = false
    /// What Start sent, shown while the screen closes (the composer's draft is cleared at once).
    @State private var sent: TaskDraft?
    @FocusState private var promptFocused: Bool

    private var draft: TaskDraft { sent ?? creator.taskDraft }
    private var mac: MacDevice? { creator.taskMac(for: draft) }
    private var folder: String? { mac.flatMap { creator.taskFolder(for: draft, on: $0.id) } }
    private var catalog: AgentCatalog? {
        if case .loaded(let catalog) = phase { return catalog }
        return nil
    }

    private var blocker: TaskStartBlocker? {
        if let blocker = creator.taskBlocker(draft) { return blocker }
        // Start names its agents, so it waits for the Mac's list.
        guard let catalog else { return .noAgent }
        if draft.picks.isEmpty, TaskComposerPhase.defaultHarness(catalog) == nil { return .noAgent }
        return nil
    }

    var body: some View {
        NavigationStack {
            canvas
                .safeAreaInset(edge: .bottom, spacing: 0) { accessory }
                .background(theme.colors.bg.color.ignoresSafeArea())
                .navigationTitle(navigationTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(action: leave) {
                            Image(systemName: "chevron.left")
                        }
                        .accessibilityLabel("Back")
                        .accessibilityIdentifier("taskComposer.cancel")
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button { showsDrafts = true } label: {
                            Image(systemName: creator.otherTaskDrafts.isEmpty ? "tray" : "tray.full")
                        }
                        .accessibilityLabel("Drafts")
                        .accessibilityValue(creator.otherTaskDrafts.isEmpty ? "" : "\(creator.otherTaskDrafts.count)")
                        .accessibilityIdentifier("taskComposer.drafts")
                    }
                }
                .sheet(isPresented: $showsOptions) {
                    TaskComposerOptionsSheet(creator: creator, sameNames: sameNames, sent: sent, blocker: blocker)
                }
                .sheet(isPresented: $showsDrafts) {
                    TaskComposerDraftsSheet(creator: creator, macName: macName)
                }
                .alert("Save this task as a draft?", isPresented: $confirmsLeave) {
                    Button("Save Draft") { finishLeaving(keep: true) }
                        .accessibilityIdentifier("taskComposer.leave.save")
                    Button("Delete Draft", role: .destructive) { finishLeaving(keep: false) }
                        .accessibilityIdentifier("taskComposer.leave.delete")
                    Button("Cancel", role: .cancel) {}
                }
                .photosPicker(isPresented: $choosingPhotos, selection: $photoItems,
                              maxSelectionCount: max(1, TaskDraft.imageLimit - draft.images.count), matching: .images)
        }
        .task(id: mac?.id) { await reload() }
        .task { await creator.taskDrafts.load() }
        .onAppear { promptFocused = true }
        // A sheet takes the keyboard away (it would cover the sheet's rows); closing it brings
        // the keyboard back. Classic kept the keyboard up over its sheets and menus.
        .onChange(of: showsOptions) { _, open in promptFocused = !open }
        .onChange(of: showsDrafts) { _, open in promptFocused = !open }
        // Leaving the app saves the draft (the app may not come back): Drafts has it.
        .onChange(of: scenePhase) { _, now in if now != .active, sent == nil { creator.saveTaskDraft() } }
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            photoItems = []
            Task { await addPhotos(items) }
        }
    }

    // MARK: Canvas

    private var canvas: some View {
        ZStack(alignment: .topLeading) {
            if draft.prompt.isEmpty {
                Text(placeholder)
                    .font(.title3)
                    .foregroundStyle(theme.colors.label3.color)
                    // On the editor's first line (its 5 pt line padding and 8 pt inset).
                    .padding(.top, 26)
                    .padding(.horizontal, 25)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            TextEditor(text: field(\.prompt))
                .font(.title3)
                .scrollContentBackground(.hidden)
                .focused($promptFocused)
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
                .accessibilityLabel("Task")
                .accessibilityHint(placeholder)
                .accessibilityIdentifier("taskComposer.prompt")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var placeholder: String {
        folder.map { "Describe a coding task in \(NewWorkspaceButton.folderName($0))" } ?? "Describe a task"
    }

    /// The name, else the folder's, else New Task (classic's title).
    private var navigationTitle: String {
        let typed = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { return typed }
        return folder.map(NewWorkspaceButton.folderName) ?? "New Task"
    }

    private var macName: String { mac.map { sameNames.displayName($0) } ?? "the Mac" }

    // MARK: Above the keyboard

    private var accessory: some View {
        VStack(spacing: 10) {
            if let refusal = creator.taskRefusal, sent == nil {
                TaskComposerBanner(title: "Couldn't start this task", message: refusal, symbol: "exclamationmark.circle.fill",
                                   tint: theme.colors.dangerText.color)
                    .accessibilityIdentifier("taskComposer.refusal")
            } else if let blocker, ![.noPrompt, .noAgent].contains(blocker) {
                TaskComposerBanner(title: nil, message: blocker.message, symbol: "exclamationmark.triangle.fill",
                                   tint: theme.colors.warning.color)
                    .accessibilityIdentifier("taskComposer.blocker")
            }
            if !draft.images.isEmpty || loadingPhotos > 0 {
                attachments
            }
            HStack(spacing: 0) {
                optionsButton
                attachMenu
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        agentsPill
                        modelPill
                    }
                    .padding(.horizontal, 6)
                }
                .trailingOverflowFade()
                startButton
            }
            .frame(height: 44)
            .padding(.horizontal, 12)
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        }
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background(theme.colors.bg.color)
    }

    private var attachments: some View {
        VStack(alignment: .leading, spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(draft.images) { image in
                        TaskImageThumb(image: image) { creator.taskDraft.images.removeAll { $0.id == image.id } }
                    }
                    ForEach(0..<loadingPhotos, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.cmuxMobileFill)
                            .frame(width: 56, height: 56)
                            .overlay { CmuxSpinner() }
                            .padding(.top, 6)
                    }
                }
                .padding(.horizontal, 16)
            }
            .accessibilityIdentifier("taskComposer.attachments")
            if draft.images.count >= TaskDraft.imageLimit {
                Text("\(TaskDraft.imageLimit) of \(TaskDraft.imageLimit) photos. A task takes up to \(TaskDraft.imageLimit).")
                    .font(theme.type.meta)
                    .foregroundStyle(theme.colors.label2.color)
                    .padding(.horizontal, 16)
                    .accessibilityIdentifier("taskComposer.photosFull")
            }
        }
    }

    /// Task Options: the workspace's name, Mac and folder (classic's sliders glyph: it sets the
    /// task up, it adds nothing).
    private var optionsButton: some View {
        Button { showsOptions = true } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.colors.label.color)
                .frame(width: 38, height: 38)
                .background(Color.cmuxMobileFill, in: .circle)
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(sent != nil)
        .accessibilityLabel("Task Options")
        .accessibilityValue([mac.map { sameNames.displayName($0) }, folder.map(NewWorkspaceButton.folderName)]
            .compactMap { $0 }.joined(separator: ", "))
        .accessibilityIdentifier("taskComposer.options")
    }

    private var attachMenu: some View {
        let full = draft.images.count >= TaskDraft.imageLimit
        return Menu {
            // Classic's order: Paste, then the library (files aren't sent with a task's first message).
            Button("Paste", systemImage: "doc.on.clipboard") { pastePhotos() }
                .disabled(full || !UIPasteboard.general.hasImages)
                .accessibilityIdentifier("taskComposer.pastePhoto")
            Button("Photo Library", systemImage: "photo.on.rectangle") { choosingPhotos = true }
                .disabled(full)
                .accessibilityIdentifier("taskComposer.addPhotos")
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 17))
                .foregroundStyle(theme.colors.label.color)
                .frame(width: 38, height: 38)
                .background(Color.cmuxMobileFill, in: .circle)
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .disabled(sent != nil)
        .accessibilityLabel(full ? "Add Photos, \(TaskDraft.imageLimit) of \(TaskDraft.imageLimit) added" : "Add Photos")
        .accessibilityIdentifier("taskComposer.attach")
    }

    /// The agents that run the task (classic's agent pill and menu). Past classic, several at
    /// once: a tap toggles an agent and the menu stays open, each picked agent has its model,
    /// and each one gets the task in its own workspace.
    private var agentsPill: some View {
        Menu {
            agentsMenu
        } label: {
            HStack(spacing: 7) {
                switch phase {
                case .loading:
                    Text("Loading agents")
                    CmuxSpinner()
                        .frame(width: 11, height: 11)
                case .failed:
                    Image(systemName: "exclamationmark.triangle").accessibilityHidden(true)
                    Text("Couldn't load agents")
                case .loaded(let catalog):
                    let shown = shownAgents(catalog)
                    if let first = shown.first {
                        AgentBrandMark(agent: first.family, size: 16, style: .brand)
                            .frame(width: 18, height: 18)
                            .accessibilityHidden(true)
                        Text(shown.count > 1 ? "\(first.name) +\(shown.count - 1)" : first.name)
                    } else {
                        Image(systemName: "person.crop.circle.badge.exclamationmark").accessibilityHidden(true)
                        Text("No agents")
                    }
                }
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(theme.colors.label2.color)
                    .accessibilityHidden(true)
            }
            .modifier(TaskComposerPillLabel(isError: agentsPillIsError))
        }
        .menuActionDismissBehavior(.disabled)
        .menuOrder(.fixed)
        .disabled(sent != nil)
        .accessibilityLabel("Agents")
        .accessibilityValue(agentsValue)
        .accessibilityIdentifier("taskComposer.agents")
    }

    @ViewBuilder private var agentsMenu: some View {
        switch phase {
        case .loading:
            Button("Loading agents…") {}
                .disabled(true)
                .accessibilityIdentifier("taskComposer.agents.loading")
        case .failed(let message):
            Button {} label: {
                Text("Couldn't load the agents")
                Text(message)
            }
            .disabled(true)
            .accessibilityIdentifier("taskComposer.agents.failed")
            Button("Try Again", systemImage: "arrow.clockwise") { Task { await reload() } }
                .accessibilityIdentifier("taskComposer.agents.retry")
        case .loaded(let catalog):
            if catalog.harnesses.isEmpty {
                Button {} label: {
                    Text("No agents")
                    Text(catalog.unavailableReason ?? "No agents are set up in cmux on this Mac.")
                }
                .disabled(true)
                .accessibilityIdentifier("taskComposer.agents.empty")
            }
            Section(draft.picks.count > 1 ? "Each gets its own workspace · up to \(TaskDraft.agentLimit)" : "Pick several to run it on each") {
                ForEach(catalog.harnesses) { harness in
                    agentItem(harness, catalog: catalog)
                }
            }
            let picked = shownAgents(catalog).filter { !$0.models.isEmpty }
            if picked.count > 1 {
                Section("Models") {
                    ForEach(picked) { harness in
                        TaskComposerModelMenu(creator: creator, harness: harness, catalog: catalog, style: .submenu)
                    }
                }
            }
        }
    }

    private func agentItem(_ harness: AgentHarnessChoice, catalog: AgentCatalog) -> some View {
        let on = draft.picks.isEmpty ? TaskComposerPhase.defaultHarness(catalog)?.id == harness.id
            : draft.picks.contains { $0.harness == harness.id }
        return Button {
            switch creator.taskDraft.toggle(harness, fallback: TaskComposerPhase.defaultHarness(catalog)) {
            case .added, .removed: theme.haptics.selection()
            case .keptLast, .atLimit: theme.haptics.warning()
            case .unavailable: break
            }
        } label: {
            if on {
                Label(harness.name, systemImage: "checkmark")
            } else {
                Text(harness.name)
            }
            if let reason = harness.unavailableReason {
                Text(reason)
            } else if TaskComposerPhase.defaultHarness(catalog)?.id == harness.id {
                Text("Default on this Mac")
            }
        }
        .disabled(!harness.canStart)
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityIdentifier("taskComposer.agent.\(harness.id)")
    }

    private var agentsPillIsError: Bool {
        switch phase {
        case .failed: true
        case .loaded(let catalog): shownAgents(catalog).isEmpty
        case .loading: false
        }
    }

    private var agentsValue: String {
        switch phase {
        case .loading: "Loading"
        case .failed(let message): message
        case .loaded(let catalog): shownAgents(catalog).map(\.name).joined(separator: ", ")
        }
    }

    /// The agents Start runs: the picks, or the agent the Mac would start.
    private func shownAgents(_ catalog: AgentCatalog) -> [AgentHarnessChoice] {
        if draft.picks.isEmpty { return TaskComposerPhase.defaultHarness(catalog).map { [$0] } ?? [] }
        return draft.picks.compactMap { catalog.harness($0.harness) }
    }

    /// The model, when one agent runs the task (with several, each agent's is in the list).
    @ViewBuilder private var modelPill: some View {
        if let catalog, shownAgents(catalog).count == 1, let harness = shownAgents(catalog).first, !harness.models.isEmpty {
            TaskComposerModelMenu(creator: creator, harness: harness, catalog: catalog, style: .pill)
                .disabled(sent != nil)
        }
    }

    private var startButton: some View {
        let count = max(1, draft.picks.count)
        let enabled = blocker == nil && loadingPhotos == 0 && sent == nil
        return Button(action: start) {
            Image(systemName: "arrow.up")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(enabled ? Color.white : theme.colors.label3.color)
                .frame(width: 38, height: 38)
                .background(enabled ? theme.colors.accent.color : Color.cmuxMobileFill, in: .circle)
                .overlay(alignment: .topTrailing) {
                    if count > 1 {
                        Text("\(count)")
                            .font(.caption2.weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(enabled ? theme.colors.accent.color : theme.colors.label2.color)
                            .frame(minWidth: 16, minHeight: 16)
                            .background(theme.colors.bg.color, in: .circle)
                            .overlay(Circle().stroke(enabled ? theme.colors.accent.color : theme.colors.label3.color, lineWidth: 1))
                            .offset(x: 5, y: -5)
                            .accessibilityHidden(true)
                    }
                }
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(count > 1 ? "Start \(count)" : "Start")
        .accessibilityHint(blocker?.message ?? (count > 1 ? "Starts the task on \(count) agents, one workspace each" : ""))
        .accessibilityIdentifier("taskComposer.start")
    }

    // MARK: Actions

    /// A text field of the draft: reads what the screen shows, writes the composer's draft.
    private func field(_ key: WritableKeyPath<TaskDraft, String>) -> Binding<String> {
        Binding(get: { draft[keyPath: key] }, set: { if sent == nil { creator.taskDraft[keyPath: key] = $0 } })
    }

    /// Back: with an unsent task not saved as it is, ask (classic's Save Draft / Delete Draft).
    private func leave() {
        guard creator.taskDraftNeedsSaving else {
            finishLeaving(keep: true)
            return
        }
        confirmsLeave = true
    }

    private func finishLeaving(keep: Bool) {
        creator.leaveTaskComposer(keep: keep)
        close()
    }

    private func start() {
        guard blocker == nil, let catalog else { return }
        var task = draft
        if task.picks.isEmpty, let harness = TaskComposerPhase.defaultHarness(catalog) {
            task.picks = [TaskAgentPick(harness: harness.id, name: harness.name)]
        }
        // Each agent's model by name: the one its menu shows, so the Mac runs what the phone said.
        task.picks = task.picks.map { pick in
            var pick = pick
            if pick.model == nil, let harness = catalog.harness(pick.harness) {
                pick.model = TaskComposerPhase.defaultModel(harness, catalog)
            }
            return pick
        }
        sent = draft
        let made = creator.startTask(task)
        guard !made.isEmpty else {
            sent = nil
            theme.haptics.warning()
            return
        }
        theme.haptics.impactLight()
        close()
        started(made)
    }

    private func reload() async {
        guard let mac else {
            phase = .failed(TaskStartBlocker.noMac.message)
            return
        }
        phase = .loading
        do {
            let catalog = try await creator.agentCatalog(on: mac.id)
            // A Mac switched meanwhile: its own load answers.
            guard !Task.isCancelled else { return }
            // Picks the Mac no longer offers (or a phone can't start) are dropped.
            creator.taskDraft.picks = creator.taskDraft.picks.filter { catalog.harness($0.harness)?.canStart == true }
            phase = .loaded(catalog)
        } catch {
            guard !Task.isCancelled else { return }
            phase = .failed((error as? LocalizedError)?.errorDescription ?? String(describing: error))
        }
    }

    private func addPhotos(_ items: [PhotosPickerItem]) async {
        let room = TaskDraft.imageLimit - draft.images.count
        let items = Array(items.prefix(max(0, room)))
        loadingPhotos += items.count
        for item in items {
            defer { loadingPhotos -= 1 }
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let image = await TaskImageEncoder.encode(data) else { continue }
            guard creator.taskDraft.images.count < TaskDraft.imageLimit else { continue }
            creator.taskDraft.images.append(image)
        }
    }

    /// Paste Photo: the pasteboard's images, encoded as picked photos are.
    private func pastePhotos() {
        let room = TaskDraft.imageLimit - draft.images.count
        let datas = (UIPasteboard.general.images ?? []).prefix(max(0, room)).compactMap { $0.pngData() }
        guard !datas.isEmpty else { return }
        loadingPhotos += datas.count
        Task {
            for data in datas {
                defer { loadingPhotos -= 1 }
                guard let image = await TaskImageEncoder.encode(data),
                      creator.taskDraft.images.count < TaskDraft.imageLimit else { continue }
                creator.taskDraft.images.append(image)
            }
        }
    }
}

/// The Mac's agent list for New Task, as loaded.
enum TaskComposerPhase: Equatable {
    case loading
    case loaded(AgentCatalog)
    case failed(String)

    /// The agent a task with no pick starts: the Mac's own pick (its last New Agent Chat),
    /// else its default. Start sends it by name, so the phone starts what it shows.
    static func defaultHarness(_ catalog: AgentCatalog) -> AgentHarnessChoice? {
        catalog.resolve(.macDefault)?.harness ?? catalog.defaultChoice
    }

    /// The model `harness` runs with no model chosen: the Mac's last pick for it, else its default.
    static func defaultModel(_ harness: AgentHarnessChoice, _ catalog: AgentCatalog) -> String? {
        catalog.resolve(AgentChatStart(harness: harness.id))?.model ?? harness.offeredDefaultModel
    }
}

/// Classic's dock pill: caption semibold on a 38 pt capsule of the label color at a low
/// opacity, inside a 44 pt target.
struct TaskComposerPillLabel: ViewModifier {
    let isError: Bool

    func body(content: Content) -> some View {
        content
            .font(.caption.weight(.semibold))
            .foregroundStyle(isError ? theme.colors.dangerText.color : theme.colors.label.color)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(minHeight: 38)
            .background(Color.cmuxMobileFill, in: .capsule)
            .frame(minHeight: 44)
            .contentShape(.rect)
    }
}

/// A warning above the controls: a refused start (with the Mac's words) or why Start is off.
struct TaskComposerBanner: View {
    let title: String?
    let message: String
    let symbol: String
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                if let title {
                    Text(title).font(.subheadline.weight(.semibold))
                }
                Text(message)
                    .font(theme.type.meta)
                    .foregroundStyle(title == nil ? theme.colors.label.color : theme.colors.label2.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 16)
        .accessibilityElement(children: .combine)
    }
}

/// An agent's model: a pill above the keyboard (one agent) or a submenu of the agents menu
/// (several, one per agent).
struct TaskComposerModelMenu: View {
    enum Style { case pill, submenu }

    @Bindable var creator: WorkspaceCreator
    let harness: AgentHarnessChoice
    let catalog: AgentCatalog
    let style: Style

    var body: some View {
        let current = creator.taskDraft.picks.first { $0.harness == harness.id }?.model
        let defaultName = TaskComposerPhase.defaultModel(harness, catalog).map { id in harness.models.first { $0.id == id }?.name ?? id }
        let label = current.map { id in harness.models.first { $0.id == id }?.name ?? id } ?? defaultName ?? "Default"
        Menu {
            Picker("Model", selection: Binding(get: { current ?? "" }, set: { setModel($0.isEmpty ? nil : $0) })) {
                Text(defaultName.map { "Default (\($0))" } ?? "Default").tag("")
                ForEach(harness.models.filter { $0.id != "default" }) { model in
                    if let reason = model.unavailableReason {
                        Text("\(model.name) — \(reason)").tag(model.id).selectionDisabled()
                    } else {
                        Text(model.name).tag(model.id)
                    }
                }
            }
        } label: {
            switch style {
            case .pill:
                HStack(spacing: 7) {
                    Image(systemName: "cpu").accessibilityHidden(true)
                    Text(label)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(theme.colors.label2.color)
                        .accessibilityHidden(true)
                }
                .modifier(TaskComposerPillLabel(isError: false))
            case .submenu:
                // A menu row: the agent, its model as the subtitle.
                Text(harness.name)
                Text(label)
            }
        }
        .accessibilityLabel("\(harness.name) model, \(label)")
        .accessibilityIdentifier(style == .pill ? "taskComposer.modelPill" : "taskComposer.model.\(harness.id)")
    }

    private func setModel(_ model: String?) {
        var picks = creator.taskDraft.picks
        if picks.isEmpty { picks = [TaskAgentPick(harness: harness.id, name: harness.name)] }
        guard let index = picks.firstIndex(where: { $0.harness == harness.id }) else { return }
        picks[index].model = model
        creator.taskDraft.picks = picks
    }
}

/// A picked photo as an agent takes it: JPEG, its long side at most 2048 px (HEIC and others
/// re-encoded), drawn off the main thread.
struct TaskImageEncoder {
    static let longSide: CGFloat = 2048
    /// One photo's most bytes as picked; past it, it is re-encoded (about 2 MB as base64).
    static let maxBytes = 1_500_000

    @concurrent
    static func encode(_ data: Data) async -> TaskImage? {
        guard let image = UIImage(data: data) else { return nil }
        let size = image.size
        let scale = min(1, longSide / max(size.width, size.height, 1))
        // Small JPEG/PNG/GIF/WebP go as they are; anything else or larger is drawn again as JPEG,
        // so six photos stay well inside one message to the Mac.
        if scale == 1, data.count <= maxBytes, TaskImage(data: data).mimeType != nil { return TaskImage(data: data) }
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let jpeg = UIGraphicsImageRenderer(size: target, format: format).jpegData(withCompressionQuality: 0.85) { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return TaskImage(data: jpeg)
    }
}

/// One attached photo with its remove button (a 44 pt target around the small corner glyph).
struct TaskImageThumb: View {
    let image: TaskImage
    let remove: () -> Void
    @State private var thumbnail: UIImage?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let thumbnail {
                    Image(uiImage: thumbnail).resizable().scaledToFill()
                } else {
                    Color.cmuxMobileFill
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.top, 6)
            .padding(.trailing, 6)
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.65))
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 44, height: 44, alignment: .topTrailing)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .offset(x: 6, y: -6)
            .accessibilityLabel("Remove photo")
        }
        .task(id: image.id) { thumbnail = await Self.thumbnail(image.data) }
        .accessibilityIdentifier("taskComposer.photo")
    }

    @concurrent
    static func thumbnail(_ data: Data) async -> UIImage? {
        UIImage(data: data)?.preparingThumbnail(of: CGSize(width: 168, height: 168))
    }
}
#endif
