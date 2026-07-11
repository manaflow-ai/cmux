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

    @State private var prompt = ""
    @State private var templates: [MobileTaskTemplate]
    @State private var selectedTemplateID: MobileTaskTemplate.ID?
    @State private var selectedMacDeviceID: String
    @State private var directory: String
    @State private var didEditDirectory = false
    @State private var isSubmitting = false
    @State private var submitTask: Task<Void, Never>?
    @State private var failureText: String?
    @State private var isEditorPresented = false
    @State private var shouldPersistDraftOnDisappear = true
    @State private var submissionIdentity: MobileTaskSubmissionIdentity

    private let composer = MobileTaskCommandComposer()
    private let sessionGeneration: Int

    init(store: CMUXMobileShellStore) {
        self.store = store
        self.sessionGeneration = store.currentSessionGeneration
        let loadedTemplates = store.taskTemplateStore?.listTemplates() ?? []
        let templates = loadedTemplates
        let draft = store.taskTemplateStore?.composerDraft()
        let foregroundMacID = store.connectedMacDeviceID
        // Restore persisted Mac IDs only while they remain paired.
        let pairedMacIDs = store.displayPairedMacs.map(\.macDeviceID)
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

                Section(L10n.string("mobile.taskComposer.directory", defaultValue: "Directory")) {
                    TextField("~", text: directoryBinding)
                        .font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit { focusedField = nil }
                        .focused($focusedField, equals: .directory)
                        .accessibilityLabel(L10n.string("mobile.taskComposer.directory", defaultValue: "Directory"))
                        .accessibilityIdentifier("MobileTaskComposerDirectory")
                }

                Section {
                    Button {
                        guard submitTask == nil else { return }
                        submitTask = Task {
                            await submit()
                            submitTask = nil
                        }
                    } label: {
                        HStack {
                            Spacer()
                            if isSubmitting {
                                ProgressView()
                            } else {
                                Text(L10n.string("mobile.taskComposer.create", defaultValue: "Create"))
                                    .fontWeight(.semibold)
                            }
                            Spacer()
                        }
                    }
                    .disabled(isSubmitting || selectedTemplate == nil || selectedMachine == nil)
                    .keyboardShortcut(.return, modifiers: .command)
                    .accessibilityLabel(
                        isSubmitting
                            ? L10n.string("mobile.taskComposer.creating", defaultValue: "Creating Task")
                            : L10n.string("mobile.taskComposer.create", defaultValue: "Create")
                    )
                    .accessibilityIdentifier("MobileTaskComposerCreateButton")

                    if let failureText {
                        Text(failureText)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("MobileTaskComposerFailure")
                    }
                }
            }
            .navigationTitle(L10n.string("mobile.taskComposer.title", defaultValue: "New Task"))
            .mobileInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("mobile.common.cancel", defaultValue: "Cancel")) {
                        submitTask?.cancel()
                        shouldPersistDraftOnDisappear = false
                        store.taskTemplateStore?.setComposerDraft(nil)
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

    private var selectedTemplate: MobileTaskTemplate? {
        selectedTemplateID.flatMap { id in templates.first { $0.id == id } }
    }

    private var machines: [MobilePairedMac] {
        store.displayPairedMacs
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
                directory = newValue
                submissionIdentity.rotate()
                didEditDirectory = true
                failureText = nil
            }
        )
    }

    private var promptBinding: Binding<String> {
        Binding(
            get: { prompt },
            set: { newValue in
                prompt = newValue
                submissionIdentity.rotate()
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
                .frame(minHeight: 44)
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
                        selectedMacDeviceID = mac.macDeviceID
                        submissionIdentity.rotate()
                        failureText = nil
                        syncSuggestedDirectory()
                    } label: {
                        HStack {
                            machineIcon(mac)
                            Text(mac.resolvedName)
                        }
                    }
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
            .accessibilityValue(selectedMachineName)
            .accessibilityIdentifier("MobileTaskComposerMachineMenu")
        }
    }

    private func templateChip(_ template: MobileTaskTemplate) -> some View {
        let isSelected = template.id == selectedTemplateID
        return Button {
            selectedTemplateID = template.id
            submissionIdentity.rotate()
            failureText = nil
            didEditDirectory = false
            syncSuggestedDirectory()
        } label: {
            HStack(spacing: 6) {
                TaskTemplateIcon(value: template.icon)
                Text(template.name)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.bordered)
        .tint(isSelected ? .accentColor : .secondary)
        .frame(minHeight: 44)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private func machineIcon(_ mac: MobilePairedMac) -> some View {
        switch MacAvatarIcon.resolve(custom: mac.customIcon, defaultSymbol: "desktopcomputer") {
        case .symbol(let name):
            Image(systemName: name)
                .accessibilityHidden(true)
        case .emoji(let emoji):
            Text(emoji)
                .accessibilityHidden(true)
        }
    }

    private func submit() async {
        guard !isSubmitting, let selectedTemplate else { return }
        isSubmitting = true
        failureText = nil
        let composition = composer.compose(template: selectedTemplate, prompt: prompt)
        let trimmedDirectory = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        let spec = MobileWorkspaceCreateSpec(
            title: composition.title,
            workingDirectory: trimmedDirectory.isEmpty ? nil : trimmedDirectory,
            initialCommand: composition.initialCommand,
            initialEnv: composition.initialEnv.isEmpty ? nil : composition.initialEnv,
            operationID: submissionIdentity.id
        )
        let result = await store.submitTaskComposer(macDeviceID: selectedMacDeviceID, spec: spec)
        isSubmitting = false
        // The user dismissed the sheet mid-flight: drop the result instead of
        // persisting last-used defaults or re-dismissing a gone sheet.
        guard !Task.isCancelled else { return }
        switch result {
        case .success:
            store.taskTemplateStore?.setLastTemplateID(selectedTemplate.id)
            store.taskTemplateStore?.setLastMacDeviceID(selectedMacDeviceID)
            store.taskTemplateStore?.setLastDirectory(trimmedDirectory.isEmpty ? nil : trimmedDirectory, macDeviceID: selectedMacDeviceID)
            shouldPersistDraftOnDisappear = false
            store.taskTemplateStore?.setComposerDraft(nil)
            dismiss()
        case .failure(let failure):
            let message = failureMessage(failure)
            failureText = message
            announceFailure(message)
        }
    }

    private func addTemplate(_ template: MobileTaskTemplate) {
        store.taskTemplateStore?.addTemplate(template)
        selectedTemplateID = template.id
        syncSuggestedDirectory()
    }

    private func updateTemplate(_ template: MobileTaskTemplate) {
        store.taskTemplateStore?.updateTemplate(template)
    }

    private func deleteTemplates(_ offsets: IndexSet) {
        for index in offsets {
            store.taskTemplateStore?.deleteTemplate(id: templates[index].id)
        }
    }

    private func refreshTemplates() {
        submissionIdentity.rotate()
        templates = store.taskTemplateStore?.listTemplates() ?? []
        failureText = nil
        if let selectedTemplateID, !templates.contains(where: { $0.id == selectedTemplateID }) {
            self.selectedTemplateID = templates.first?.id
        }
        // Sync template edits unless the user typed the directory.
        syncSuggestedDirectory()
    }

    private func validateMacSelection() {
        guard selectedMachine == nil else { return }
        selectedMacDeviceID = machines.first?.macDeviceID ?? ""
        submissionIdentity.rotate()
        failureText = nil
        syncSuggestedDirectory()
    }

    private func persistDraft() {
        guard shouldPersistDraftOnDisappear else { return }
        store.persistTaskComposerDraft(
            MobileTaskComposerDraft(
                prompt: prompt,
                templateID: selectedTemplateID,
                macDeviceID: selectedMacDeviceID.isEmpty ? nil : selectedMacDeviceID,
                directory: directory,
                didEditDirectory: didEditDirectory,
                operationID: submissionIdentity.id
            ),
            ifSessionGeneration: sessionGeneration
        )
    }

    private func announceFailure(_ message: String) {
        guard UIAccessibility.isVoiceOverRunning else { return }
        AccessibilityNotification.Announcement(message).post()
    }

    private func validationText(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    /// Recompute the suggested directory unless the user hand-edited it.
    private func syncSuggestedDirectory() {
        guard !didEditDirectory else { return }
        directory = Self.suggestedDirectory(
            template: selectedTemplate,
            macDeviceID: selectedMacDeviceID,
            templateStore: store.taskTemplateStore
        )
    }

    private func failureMessage(_ failure: MobileWorkspaceMutationFailure) -> String {
        switch failure {
        case .notConnected:
            return L10n.string("mobile.taskComposer.failure.notConnected", defaultValue: "That Mac is not connected.")
        case .requestTimedOut:
            return L10n.string("mobile.taskComposer.failure.timedOut", defaultValue: "The Mac did not respond in time.")
        case .authorizationFailed:
            return L10n.string("mobile.taskComposer.failure.authorization", defaultValue: "That Mac did not authorize the request.")
        case .busy:
            return L10n.string("mobile.taskComposer.failure.busy", defaultValue: "Another workspace action is still finishing.")
        case .rejected:
            return L10n.string("mobile.taskComposer.failure.rejected", defaultValue: "The Mac rejected the task.")
        case .unsupported:
            return L10n.string("mobile.taskComposer.failure.unsupported", defaultValue: "That Mac does not support this action.")
        }
    }

    /// The directory the composer pre-fills: the template default, then the
    /// last successful directory for the selected Mac, then home. Static: it
    /// runs in `init` before `self` exists, and the package conventions lint
    /// forbids free functions in iOS package sources.
    private static func suggestedDirectory(
        template: MobileTaskTemplate?,
        macDeviceID: String,
        templateStore: (any MobileTaskTemplateStoring)?
    ) -> String {
        if let defaultDirectory = template?.defaultDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
           !defaultDirectory.isEmpty {
            return defaultDirectory
        }
        if let lastDirectory = templateStore?.lastDirectory(macDeviceID: macDeviceID)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !lastDirectory.isEmpty {
            return lastDirectory
        }
        return "~"
    }
}
#endif
