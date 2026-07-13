#if os(iOS)
import CmuxMobilePairedMac
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI
import UIKit

struct TaskComposerSheet: View {
    private enum Field: Hashable {
        case prompt
        case directory
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Bindable var store: CMUXMobileShellStore
    @FocusState private var focusedField: Field?

    @State var prompt = ""
    @State private var templates: [MobileTaskTemplate]
    @State var selectedTemplateID: MobileTaskTemplate.ID?
    @State var selectedMacDeviceID: String
    @State var directory: String
    @State var didEditDirectory = false
    @State private var isSubmitting = false
    @State private var submitTask: Task<Void, Never>?
    @State private var failureText: String?
    @State private var isEditorPresented = false
    @State private var shouldPersistDraftOnDisappear = true
    @State var submissionIdentity: MobileTaskSubmissionIdentity
    @State private var activeSubmissionSnapshot: MobileTaskSubmissionSnapshot?

    private let sessionGeneration: Int
    private let availableMachines: [MobilePairedMac]?
    private let submitTaskComposer: @MainActor (
        _ macDeviceID: String,
        _ spec: MobileWorkspaceCreateSpec
    ) async -> Result<Void, MobileWorkspaceMutationFailure>

    init(
        store: CMUXMobileShellStore,
        availableMachines: [MobilePairedMac]? = nil,
        submitTaskComposer: (@MainActor (
            _ macDeviceID: String,
            _ spec: MobileWorkspaceCreateSpec
        ) async -> Result<Void, MobileWorkspaceMutationFailure>)? = nil
    ) {
        self.store = store
        self.availableMachines = availableMachines
        self.sessionGeneration = store.currentSessionGeneration
        self.submitTaskComposer = submitTaskComposer ?? { macDeviceID, spec in
            await store.submitTaskComposer(macDeviceID: macDeviceID, spec: spec)
        }
        let loadedTemplates = store.taskTemplateStore?.listTemplates() ?? []
        let templates = loadedTemplates
        let draft = store.taskTemplateStore?.composerDraft()
        let foregroundMacID = store.connectedMacDeviceID
        // Restore persisted Mac IDs only while they remain paired.
        let pairedMacIDs = (availableMachines ?? store.displayPairedMacs).map(\.macDeviceID)
        let restoredMacID = store.taskTemplateStore?.lastMacDeviceID()
            .flatMap { id in pairedMacIDs.contains(id) ? id : nil }
        let draftMacID = draft?.macDeviceID
            .flatMap { id in pairedMacIDs.contains(id) ? id : nil }
        let selectedMacID = draftMacID
            ?? restoredMacID
            ?? foregroundMacID.flatMap { id in pairedMacIDs.contains(id) ? id : nil }
            ?? pairedMacIDs.first
            ?? foregroundMacID
            ?? ""
        let draftTemplateID = draft?.templateID
            .flatMap { id in templates.contains(where: { $0.id == id }) ? id : nil }
        let selectedTemplateID = draftTemplateID
            ?? store.taskTemplateStore?.lastTemplateID()
            .flatMap { id in templates.contains(where: { $0.id == id }) ? id : nil }
            ?? templates.first?.id
        let selectedTemplate = selectedTemplateID.flatMap { id in templates.first { $0.id == id } }
        let canRestoreDraftDirectory = draft != nil && (
            draft?.didEditDirectory == true
                || (draft?.templateID == selectedTemplateID && draft?.macDeviceID == selectedMacID)
        )
        let initialDirectory = canRestoreDraftDirectory
            ? draft?.directory ?? "~"
            : Self.suggestedDirectory(
                template: selectedTemplate,
                macDeviceID: selectedMacID,
                templateStore: store.taskTemplateStore
            )
        let restoredOperationID = (
            draft?.templateID == selectedTemplateID
                && draft?.macDeviceID == (selectedMacID.isEmpty ? nil : selectedMacID)
                && canRestoreDraftDirectory
        ) ? draft?.operationID : nil
        _prompt = State(initialValue: draft?.prompt ?? "")
        _templates = State(initialValue: templates)
        _selectedTemplateID = State(initialValue: selectedTemplateID)
        _selectedMacDeviceID = State(initialValue: selectedMacID)
        _directory = State(initialValue: initialDirectory)
        _didEditDirectory = State(initialValue: canRestoreDraftDirectory && draft?.didEditDirectory == true)
        _submissionIdentity = State(initialValue: MobileTaskSubmissionIdentity(id: restoredOperationID ?? UUID()))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.string("mobile.taskComposer.prompt", defaultValue: "Prompt")) {
                    TextField(
                        L10n.string("mobile.taskComposer.promptPlaceholder", defaultValue: "Describe the task"),
                        text: promptBinding,
                        axis: .vertical
                    )
                    .lineLimit(3...8)
                    .focused($focusedField, equals: .prompt)
                    .disabled(isSubmitting)
                    .accessibilityIdentifier("MobileTaskComposerPrompt")
                }

                Section(L10n.string("mobile.taskComposer.template", defaultValue: "Template")) {
                    templatePicker
                    if templates.isEmpty {
                        validationText(
                            L10n.string(
                                "mobile.taskComposer.validation.template",
                                defaultValue: "Add a template before creating a task."
                            )
                        )
                    }
                }
                .disabled(isSubmitting)

                Section(L10n.string("mobile.taskComposer.machine", defaultValue: "Machine")) {
                    machineMenu
                    if machines.isEmpty {
                        validationText(
                            L10n.string(
                                "mobile.taskComposer.validation.machine",
                                defaultValue: "Pair a Mac before creating a task."
                            )
                        )
                    }
                }
                .disabled(isSubmitting)

                Section(L10n.string("mobile.taskComposer.directory", defaultValue: "Directory")) {
                    TextField("~", text: directoryBinding)
                        .font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit { focusedField = nil }
                        .focused($focusedField, equals: .directory)
                        .disabled(isSubmitting)
                        .accessibilityLabel(L10n.string("mobile.taskComposer.directory", defaultValue: "Directory"))
                        .accessibilityIdentifier("MobileTaskComposerDirectory")
                }

                if let failureText {
                    Section {
                        Text(failureText)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("MobileTaskComposerFailure")
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                TaskComposerPrimaryAction(
                    isSubmitting: isSubmitting,
                    isEnabled: selectedTemplate != nil && selectedMachine != nil,
                    action: startSubmission
                )
            }
            .navigationTitle(L10n.string("mobile.taskComposer.title", defaultValue: "New Task"))
            .mobileInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("mobile.common.cancel", defaultValue: "Cancel")) {
                        submitTask?.cancel()
                        shouldPersistDraftOnDisappear = false
                        store.clearTaskComposerDraft(ifSessionGeneration: sessionGeneration)
                        dismiss()
                    }
                    // Keep the sheet up until the sent RPC finishes.
                    .disabled(isSubmitting)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button(L10n.string("mobile.common.done", defaultValue: "Done")) {
                        focusedField = nil
                    }
                }
            }
            .sheet(isPresented: $isEditorPresented) {
                TaskTemplateEditorView(
                    templates: templates,
                    addTemplate: addTemplate,
                    updateTemplate: updateTemplate,
                    deleteTemplates: deleteTemplates,
                    refresh: refreshTemplates
                )
            }
            .onAppear {
                focusedField = .prompt
            }
            .onDisappear {
                // Parent-driven dismissal must cancel result application.
                submitTask?.cancel()
                if shouldPersistDraftOnDisappear {
                    persistDraft()
                }
            }
            .onChange(of: scenePhase) { _, newPhase in
                guard newPhase != .active else { return }
                persistDraft()
            }
            .onChange(of: machines.map(\.macDeviceID)) { _, _ in
                validateMacSelection()
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(isSubmitting)
    }

    var selectedTemplate: MobileTaskTemplate? {
        selectedTemplateID.flatMap { id in templates.first { $0.id == id } }
    }

    private var machines: [MobilePairedMac] {
        availableMachines ?? store.displayPairedMacs
    }

    private var selectedMachineName: String {
        selectedMachine?.resolvedName
            ?? selectedMacDeviceID
    }

    private var selectedMachine: MobilePairedMac? {
        machines.first { $0.macDeviceID == selectedMacDeviceID }
    }

    private var directoryBinding: Binding<String> {
        Binding(
            get: { directory },
            set: { newValue in
                guard !isSubmitting else { return }
                updateSubmissionRequest {
                    directory = newValue
                    didEditDirectory = true
                }
                failureText = nil
            }
        )
    }

    private var promptBinding: Binding<String> {
        Binding(
            get: { prompt },
            set: { newValue in
                guard !isSubmitting else { return }
                updateSubmissionRequest {
                    prompt = newValue
                }
                failureText = nil
            }
        )
    }

    private var templatePicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(templates) { template in
                    templateChip(template)
                }
                Button {
                    persistDraft()
                    isEditorPresented = true
                } label: {
                    Label(L10n.string("mobile.common.edit", defaultValue: "Edit"), systemImage: "pencil")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            .padding(.vertical, 2)
        }
    }

    @ViewBuilder
    private var machineMenu: some View {
        if machines.isEmpty {
            Text(L10n.string("mobile.taskComposer.machine.none", defaultValue: "No paired Macs"))
                .foregroundStyle(.secondary)
        } else {
            Menu {
                ForEach(machines) { mac in
                    Button {
                        guard !isSubmitting else { return }
                        updateSubmissionRequest {
                            selectedMacDeviceID = mac.macDeviceID
                            syncSuggestedDirectory()
                        }
                        failureText = nil
                    } label: {
                        HStack {
                            machineIcon(mac)
                            Text(mac.resolvedName)
                        }
                    }
                    .accessibilityAddTraits(mac.macDeviceID == selectedMacDeviceID ? .isSelected : [])
                }
            } label: {
                HStack(spacing: 10) {
                    if let mac = machines.first(where: { $0.macDeviceID == selectedMacDeviceID }) {
                        machineIcon(mac)
                    }
                    Text(selectedMachineName)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityLabel(L10n.string("mobile.taskComposer.machine", defaultValue: "Machine"))
            .accessibilityHint(Self.machineAccessibilityHint)
            .accessibilityValue(selectedMachineName)
            .accessibilityIdentifier("MobileTaskComposerMachineMenu")
        }
    }

    private func templateChip(_ template: MobileTaskTemplate) -> some View {
        let isSelected = template.id == selectedTemplateID
        return Button {
            guard !isSubmitting else { return }
            selectTemplate(template)
            failureText = nil
        } label: {
            HStack(spacing: 6) {
                TaskTemplateIcon(value: template.icon)
                Text(template.name)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .tint(isSelected ? .accentColor : .secondary)
        .accessibilityHint(Self.templateAccessibilityHint)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func startSubmission() {
        guard submitTask == nil else { return }
        submitTask = Task {
            await submit()
            submitTask = nil
        }
    }

    private func submit() async {
        guard !isSubmitting, let selectedTemplate else { return }
        let snapshot = MobileTaskSubmissionSnapshot(
            template: selectedTemplate,
            prompt: prompt,
            macDeviceID: selectedMacDeviceID,
            directory: directory,
            didEditDirectory: didEditDirectory,
            operationID: submissionIdentity.id
        )
        isSubmitting = true
        activeSubmissionSnapshot = snapshot
        failureText = nil
        let spec = MobileWorkspaceCreateSpec(
            title: snapshot.composition.title,
            workingDirectory: snapshot.trimmedDirectory.isEmpty ? nil : snapshot.trimmedDirectory,
            initialCommand: snapshot.composition.initialCommand,
            initialEnv: snapshot.composition.initialEnv.isEmpty ? nil : snapshot.composition.initialEnv,
            operationID: snapshot.operationID
        )
        let result = await submitTaskComposer(snapshot.macDeviceID, spec)
        isSubmitting = false
        activeSubmissionSnapshot = nil
        // The user dismissed the sheet mid-flight: drop the result instead of
        // persisting last-used defaults or re-dismissing a gone sheet.
        guard !Task.isCancelled else { return }
        switch result {
        case .success:
            store.taskTemplateStore?.setLastTemplateID(snapshot.templateID)
            store.taskTemplateStore?.setLastMacDeviceID(snapshot.macDeviceID)
            store.taskTemplateStore?.setLastDirectory(
                snapshot.trimmedDirectory.isEmpty ? nil : snapshot.trimmedDirectory,
                macDeviceID: snapshot.macDeviceID
            )
            shouldPersistDraftOnDisappear = false
            store.clearTaskComposerDraft(ifSessionGeneration: sessionGeneration)
            dismiss()
        case .failure(let failure):
            restoreSubmittedDraft(snapshot)
            _ = store.persistTaskComposerDraft(snapshot.draft, ifSessionGeneration: sessionGeneration)
            let message = Self.failureMessage(failure)
            failureText = message
            announceFailure(message)
        }
    }

    private func addTemplate(_ template: MobileTaskTemplate) {
        guard !isSubmitting else { return }
        store.taskTemplateStore?.addTemplate(template)
        selectedTemplateID = template.id
        syncSuggestedDirectory()
    }

    private func updateTemplate(_ template: MobileTaskTemplate) {
        guard !isSubmitting else { return }
        store.taskTemplateStore?.updateTemplate(template)
    }

    private func deleteTemplates(_ offsets: IndexSet) {
        guard !isSubmitting else { return }
        for index in offsets {
            store.taskTemplateStore?.deleteTemplate(id: templates[index].id)
        }
    }

    private func refreshTemplates() {
        guard !isSubmitting else { return }
        updateSubmissionRequest {
            templates = store.taskTemplateStore?.listTemplates() ?? []
            if let selectedTemplateID, !templates.contains(where: { $0.id == selectedTemplateID }) {
                self.selectedTemplateID = templates.first?.id
            }
            // Sync template edits unless the user typed the directory.
            syncSuggestedDirectory()
        }
        failureText = nil
    }

    private func validateMacSelection() {
        guard !isSubmitting else { return }
        guard selectedMachine == nil else { return }
        updateSubmissionRequest {
            selectedMacDeviceID = machines.first?.macDeviceID ?? ""
            syncSuggestedDirectory()
        }
        failureText = nil
    }

    private func persistDraft() {
        guard shouldPersistDraftOnDisappear else { return }
        if let activeSubmissionSnapshot {
            store.persistTaskComposerDraft(
                activeSubmissionSnapshot.draft,
                ifSessionGeneration: sessionGeneration
            )
            return
        }
        store.persistTaskComposerDraft(draftSnapshot(), ifSessionGeneration: sessionGeneration)
    }

    private func announceFailure(_ message: String) {
        guard UIAccessibility.isVoiceOverRunning else { return }
        AccessibilityNotification.Announcement(message).post()
    }

}
#endif
