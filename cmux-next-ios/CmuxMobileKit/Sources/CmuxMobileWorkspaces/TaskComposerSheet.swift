#if os(iOS)
import CmuxAgentBrands
import CmuxMobileDesign
import CmuxMobileModel
import CmuxSpinner
import PhotosUI
import SwiftUI
import UIKit

private let theme = CmuxMobileTheme.standard

/// New Task: write what to do, choose the agents that do it (each in its own new workspace,
/// with its model), the Mac and folder, a name and photos, then Start. Start closes the sheet
/// at once: the workspaces are optimistic rows, and each agent gets the task as its first
/// message. The draft (`WorkspaceCreator.taskDraft`) outlives the sheet.
struct TaskComposerSheet: View {
    @Bindable var creator: WorkspaceCreator
    /// The team's same-name Macs, tagged as the filter menu tags them.
    let sameNames: MacNameDisambiguation
    /// Runs after Start with the new placeholders (one: the list opens it).
    let started: ([Workspace]) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var phase: Phase = .loading
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var loadingPhotos = 0
    @FocusState private var promptFocused: Bool

    enum Phase: Equatable {
        case loading
        case loaded(AgentCatalog)
        case failed(String)
    }

    private var draft: TaskDraft { creator.taskDraft }
    private var mac: MacDevice? { creator.taskMac(for: draft) }
    private var folders: [String] { mac.map { creator.taskFolders(on: $0.id) } ?? [] }
    private var folder: String? { mac.flatMap { creator.taskFolder(for: draft, on: $0.id) } }
    private var blocker: TaskStartBlocker? {
        if let blocker = creator.taskBlocker(draft) { return blocker }
        if case .loaded(let catalog) = phase, draft.picks.isEmpty, catalog.defaultChoice == nil { return .noAgent }
        return nil
    }

    var body: some View {
        NavigationStack {
            Form {
                promptSection
                agentsSection
                whereSection
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("New Task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("taskComposer.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(startTitle) { start() }
                        .fontWeight(.semibold)
                        .disabled(blocker != nil || loadingPhotos > 0)
                        .accessibilityIdentifier("taskComposer.start")
                        .accessibilityHint(blocker?.message ?? "")
                }
            }
        }
        .task(id: mac?.id) { await reload() }
        .onAppear { promptFocused = true }
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            photoItems = []
            Task { await addPhotos(items) }
        }
    }

    /// "Start", or "Start 3" when the task runs on three agents.
    private var startTitle: String { draft.picks.count > 1 ? "Start \(draft.picks.count)" : "Start" }

    // MARK: Prompt

    private var promptSection: some View {
        Section {
            TextField("Describe the task…", text: $creator.taskDraft.prompt, axis: .vertical)
                .lineLimit(4...12)
                .focused($promptFocused)
                .accessibilityIdentifier("taskComposer.prompt")
            if !draft.images.isEmpty || loadingPhotos > 0 {
                attachments
            }
            PhotosPicker(selection: $photoItems, maxSelectionCount: max(1, TaskDraft.imageLimit - draft.images.count),
                         matching: .images) {
                Label(draft.images.isEmpty ? "Add Photos" : "Add More Photos", systemImage: "photo.on.rectangle.angled")
            }
            .disabled(draft.images.count >= TaskDraft.imageLimit)
            .accessibilityIdentifier("taskComposer.addPhotos")
        } footer: {
            if draft.images.count >= TaskDraft.imageLimit {
                Text("A task takes up to \(TaskDraft.imageLimit) photos.")
            }
        }
    }

    private var attachments: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(draft.images) { image in
                    TaskImageThumb(image: image) { remove(image) }
                }
                ForEach(0..<loadingPhotos, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(theme.colors.fill.color)
                        .frame(width: 64, height: 64)
                        .overlay { CmuxSpinner() }
                }
            }
            .padding(.vertical, 4)
        }
        .accessibilityIdentifier("taskComposer.attachments")
    }

    // MARK: Agents

    @ViewBuilder private var agentsSection: some View {
        Section {
            switch phase {
            case .loading:
                HStack(spacing: 10) {
                    CmuxSpinner()
                    Text("Loading agents…").foregroundStyle(theme.colors.label2.color)
                }
                .accessibilityIdentifier("taskComposer.agents.loading")
            case .failed(let message):
                VStack(alignment: .leading, spacing: 6) {
                    Label("Couldn't load the agents", systemImage: "exclamationmark.circle")
                    Text(message).font(theme.type.meta).foregroundStyle(theme.colors.label2.color)
                    Button("Try Again") { Task { await reload() } }
                        .accessibilityIdentifier("taskComposer.agents.retry")
                }
                .accessibilityIdentifier("taskComposer.agents.failed")
            case .loaded(let catalog):
                if catalog.harnesses.isEmpty {
                    Text(catalog.unavailableReason ?? "No agents are set up in cmux on this Mac.")
                        .foregroundStyle(theme.colors.label2.color)
                        .accessibilityIdentifier("taskComposer.agents.empty")
                }
                ForEach(catalog.harnesses) { harness in
                    agentRow(harness, catalog: catalog)
                }
            }
        } header: {
            Text("Agents")
        } footer: {
            Text(agentsFooter)
        }
    }

    private var agentsFooter: String {
        let count = max(draft.picks.count, 1)
        return count == 1 ? "The task opens in a new workspace with this agent."
            : "Each agent gets the task in its own new workspace (\(count) workspaces)."
    }

    /// Whether `harness` runs the task: chosen, or the Mac's default while nothing is chosen.
    private func isOn(_ harness: AgentHarnessChoice, _ catalog: AgentCatalog) -> Bool {
        draft.picks.isEmpty ? catalog.defaultChoice?.id == harness.id : draft.picks.contains { $0.harness == harness.id }
    }

    private func agentRow(_ harness: AgentHarnessChoice, catalog: AgentCatalog) -> some View {
        let on = isOn(harness, catalog)
        return HStack(spacing: 12) {
            Button {
                toggle(harness, catalog: catalog)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: on ? "checkmark.circle.fill" : "circle")
                        .font(theme.type.body)
                        .foregroundStyle(on ? theme.colors.accent.color : theme.colors.label3.color)
                        .accessibilityHidden(true)
                    AgentBrandMark(agent: harness.family, size: 22, style: .brand)
                        .opacity(harness.canStart ? 1 : 0.4)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(harness.name)
                            .foregroundStyle(harness.canStart ? theme.colors.label.color : theme.colors.label2.color)
                        if let reason = harness.unavailableReason {
                            Text(reason).font(theme.type.meta).foregroundStyle(theme.colors.label2.color)
                        } else if harness.isDefault {
                            Text("Default on this Mac").font(theme.type.meta).foregroundStyle(theme.colors.label2.color)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!harness.canStart)
            .accessibilityAddTraits(on ? .isSelected : [])
            .accessibilityIdentifier("taskComposer.agent.\(harness.id)")
            if on, !harness.models.isEmpty {
                modelMenu(harness)
            }
        }
    }

    private func modelMenu(_ harness: AgentHarnessChoice) -> some View {
        let current = draft.picks.first { $0.harness == harness.id }?.model
        let defaultName = harness.offeredDefaultModel.map { id in harness.models.first { $0.id == id }?.name ?? id }
        let label = current.map { id in harness.models.first { $0.id == id }?.name ?? id } ?? defaultName ?? "Default"
        return Menu {
            Picker("Model", selection: Binding(get: { current ?? "" }, set: { setModel($0.isEmpty ? nil : $0, for: harness) })) {
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
            HStack(spacing: 4) {
                Text(label).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").imageScale(.small)
            }
            .font(theme.type.meta)
            .foregroundStyle(theme.colors.accent.color)
        }
        .accessibilityLabel("\(harness.name) model, \(label)")
        .accessibilityIdentifier("taskComposer.model.\(harness.id)")
    }

    // MARK: Where

    private var whereSection: some View {
        Section {
            let macs = creator.taskMacs
            if macs.count > 1, let mac {
                Picker(selection: Binding(get: { mac.id }, set: { creator.taskDraft.macID = $0; creator.taskDraft.picks = [] })) {
                    ForEach(macs) { Text(sameNames.displayName($0)).tag($0.id) }
                } label: {
                    Label("Mac", systemImage: "desktopcomputer")
                }
                .accessibilityIdentifier("taskComposer.mac")
            } else if let mac {
                LabeledContent {
                    Text(sameNames.displayName(mac))
                } label: {
                    Label("Mac", systemImage: "desktopcomputer")
                }
            }
            if folders.isEmpty {
                LabeledContent {
                    Text("None open").foregroundStyle(theme.colors.label2.color)
                } label: {
                    Label("Folder", systemImage: "folder")
                }
                .accessibilityIdentifier("taskComposer.folder.none")
            } else {
                Picker(selection: Binding(get: { folder ?? "" }, set: { creator.taskDraft.directory = $0 })) {
                    ForEach(folders, id: \.self) { directory in
                        Text(NewWorkspaceButton.folderName(directory)).tag(directory)
                    }
                } label: {
                    Label("Folder", systemImage: "folder")
                }
                .accessibilityIdentifier("taskComposer.folder")
            }
            TextField(text: $creator.taskDraft.name, prompt: Text(draft.title)) {
                Label("Name", systemImage: "character.cursor.ibeam")
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.done)
            .accessibilityIdentifier("taskComposer.name")
        } header: {
            Text("Workspace")
        } footer: {
            if let blocker, blocker != .noPrompt {
                Text(blocker.message)
                    .foregroundStyle(blocker == .noFolder || blocker == .noMac ? theme.colors.warning.color : theme.colors.label2.color)
                    .accessibilityIdentifier("taskComposer.blocker")
            } else if let folder {
                Text(folder)
            }
        }
    }

    // MARK: Actions

    private func toggle(_ harness: AgentHarnessChoice, catalog: AgentCatalog) {
        guard harness.canStart else { return }
        theme.haptics.selection()
        var picks = draft.picks
        // The Mac's default shown as chosen becomes a real pick once another is added.
        if picks.isEmpty, let fallback = catalog.defaultChoice { picks = [TaskAgentPick(harness: fallback.id, name: fallback.name)] }
        if let index = picks.firstIndex(where: { $0.harness == harness.id }) {
            guard picks.count > 1 else { return }
            picks.remove(at: index)
        } else {
            guard picks.count < TaskDraft.agentLimit else {
                theme.haptics.warning()
                return
            }
            picks.append(TaskAgentPick(harness: harness.id, name: harness.name))
        }
        creator.taskDraft.picks = picks
    }

    private func setModel(_ model: String?, for harness: AgentHarnessChoice) {
        var picks = draft.picks
        if picks.isEmpty { picks = [TaskAgentPick(harness: harness.id, name: harness.name)] }
        guard let index = picks.firstIndex(where: { $0.harness == harness.id }) else { return }
        picks[index].model = model
        creator.taskDraft.picks = picks
    }

    private func remove(_ image: TaskImage) {
        creator.taskDraft.images.removeAll { $0.id == image.id }
    }

    private func start() {
        guard blocker == nil else { return }
        let made = creator.startTask(draft)
        guard !made.isEmpty else {
            theme.haptics.warning()
            return
        }
        theme.haptics.impactLight()
        dismiss()
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
            // Picks the Mac no longer offers (or a phone can't start) are dropped.
            creator.taskDraft.picks = draft.picks.filter { catalog.harness($0.harness)?.canStart == true }
            phase = .loaded(catalog)
        } catch {
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
}

/// A picked photo as an agent takes it: JPEG, its long side at most 2048 px (HEIC and others
/// re-encoded), drawn off the main thread.
struct TaskImageEncoder {
    static let longSide: CGFloat = 2048

    @concurrent
    static func encode(_ data: Data) async -> TaskImage? {
        guard let image = UIImage(data: data) else { return nil }
        let size = image.size
        let scale = min(1, longSide / max(size.width, size.height, 1))
        if scale == 1, TaskImage(data: data).mimeType != nil { return TaskImage(data: data) }
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let jpeg = UIGraphicsImageRenderer(size: target, format: format).jpegData(withCompressionQuality: 0.85) { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return TaskImage(data: jpeg)
    }
}

/// One attached photo with its remove button.
private struct TaskImageThumb: View {
    let image: TaskImage
    let remove: () -> Void
    @State private var thumbnail: UIImage?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let thumbnail {
                    Image(uiImage: thumbnail).resizable().scaledToFill()
                } else {
                    theme.colors.fill.color
                }
            }
            .frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.6))
                    .font(theme.type.body)
            }
            .buttonStyle(.plain)
            .offset(x: 6, y: -6)
            .accessibilityLabel("Remove photo")
        }
        .padding(.top, 6)
        .padding(.trailing, 6)
        .task(id: image.id) { thumbnail = await Self.thumbnail(image.data) }
        .accessibilityIdentifier("taskComposer.photo")
    }

    @concurrent
    static func thumbnail(_ data: Data) async -> UIImage? {
        UIImage(data: data)?.preparingThumbnail(of: CGSize(width: 192, height: 192))
    }
}
#endif
