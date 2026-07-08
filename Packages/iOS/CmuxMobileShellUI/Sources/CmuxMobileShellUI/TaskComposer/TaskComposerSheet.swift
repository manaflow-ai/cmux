#if os(iOS)
import CmuxMobilePairedMac
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

struct TaskComposerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: CMUXMobileShellStore
    @FocusState private var isPromptFocused: Bool

    @State private var prompt = ""
    @State private var templates: [MobileTaskTemplate]
    @State private var selectedTemplateID: MobileTaskTemplate.ID?
    @State private var selectedMacDeviceID: String
    @State private var directory: String
    @State private var didEditDirectory = false
    @State private var isSubmitting = false
    @State private var failureText: String?
    @State private var isEditorPresented = false

    private let composer = MobileTaskCommandComposer()

    init(store: CMUXMobileShellStore) {
        self.store = store
        let loadedTemplates = store.taskTemplateStore?.listTemplates() ?? []
        let templates = loadedTemplates
        let foregroundMacID = store.connectedMacDeviceID
        let fallbackMacID = store.taskTemplateStore?.lastMacDeviceID()
            ?? store.displayPairedMacs.first?.macDeviceID
            ?? foregroundMacID
            ?? ""
        let selectedMacID = foregroundMacID ?? fallbackMacID
        let selectedTemplateID = store.taskTemplateStore?.lastTemplateID()
            .flatMap { id in templates.contains(where: { $0.id == id }) ? id : nil }
            ?? templates.first?.id
        let selectedTemplate = selectedTemplateID.flatMap { id in templates.first { $0.id == id } }
        let initialDirectory = Self.suggestedDirectory(
            template: selectedTemplate,
            macDeviceID: selectedMacID,
            templateStore: store.taskTemplateStore
        )
        _templates = State(initialValue: templates)
        _selectedTemplateID = State(initialValue: selectedTemplateID)
        _selectedMacDeviceID = State(initialValue: selectedMacID)
        _directory = State(initialValue: initialDirectory)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.string("mobile.taskComposer.prompt", defaultValue: "Prompt")) {
                    TextField(
                        L10n.string("mobile.taskComposer.promptPlaceholder", defaultValue: "Describe the task"),
                        text: $prompt,
                        axis: .vertical
                    )
                    .lineLimit(3...8)
                    .focused($isPromptFocused)
                    .accessibilityIdentifier("MobileTaskComposerPrompt")
                }

                Section(L10n.string("mobile.taskComposer.template", defaultValue: "Template")) {
                    templatePicker
                }

                Section(L10n.string("mobile.taskComposer.machine", defaultValue: "Machine")) {
                    machineMenu
                }

                Section(L10n.string("mobile.taskComposer.directory", defaultValue: "Directory")) {
                    TextField("~", text: directoryBinding)
                        .font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("MobileTaskComposerDirectory")
                }

                Section {
                    Button {
                        Task { await submit() }
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
                    .disabled(isSubmitting || selectedTemplate == nil || selectedMacDeviceID.isEmpty)
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
                        dismiss()
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
                isPromptFocused = true
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var selectedTemplate: MobileTaskTemplate? {
        selectedTemplateID.flatMap { id in templates.first { $0.id == id } }
    }

    private var machines: [MobilePairedMac] {
        store.displayPairedMacs
    }

    private var selectedMachineName: String {
        machines.first { $0.macDeviceID == selectedMacDeviceID }?.resolvedName
            ?? selectedMacDeviceID
    }

    private var directoryBinding: Binding<String> {
        Binding(
            get: { directory },
            set: { newValue in
                directory = newValue
                didEditDirectory = true
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
                    isEditorPresented = true
                } label: {
                    Label(L10n.string("mobile.common.edit", defaultValue: "Edit"), systemImage: "pencil")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.bordered)
            }
            .padding(.vertical, 2)
        }
    }

    private var machineMenu: some View {
        Menu {
            ForEach(machines) { mac in
                Button {
                    selectedMacDeviceID = mac.macDeviceID
                    if !didEditDirectory {
                        directory = Self.suggestedDirectory(
                            template: selectedTemplate,
                            macDeviceID: mac.macDeviceID,
                            templateStore: store.taskTemplateStore
                        )
                    }
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
        .accessibilityIdentifier("MobileTaskComposerMachineMenu")
    }

    private func templateChip(_ template: MobileTaskTemplate) -> some View {
        let isSelected = template.id == selectedTemplateID
        return Button {
            selectedTemplateID = template.id
            failureText = nil
            didEditDirectory = false
            directory = Self.suggestedDirectory(
                template: template,
                macDeviceID: selectedMacDeviceID,
                templateStore: store.taskTemplateStore
            )
        } label: {
            HStack(spacing: 6) {
                TaskTemplateIcon(value: template.icon)
                Text(template.name)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.bordered)
        .tint(isSelected ? .accentColor : .secondary)
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
        guard let selectedTemplate else { return }
        isSubmitting = true
        failureText = nil
        let composition = composer.compose(template: selectedTemplate, prompt: prompt)
        let trimmedDirectory = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        let spec = MobileWorkspaceCreateSpec(
            title: composition.title,
            workingDirectory: trimmedDirectory.isEmpty ? nil : trimmedDirectory,
            initialCommand: composition.initialCommand,
            initialEnv: composition.initialEnv.isEmpty ? nil : composition.initialEnv
        )
        let result = await store.submitTaskComposer(macDeviceID: selectedMacDeviceID, spec: spec)
        isSubmitting = false
        switch result {
        case .success:
            store.taskTemplateStore?.setLastTemplateID(selectedTemplate.id)
            store.taskTemplateStore?.setLastMacDeviceID(selectedMacDeviceID)
            store.taskTemplateStore?.setLastDirectory(trimmedDirectory.isEmpty ? nil : trimmedDirectory, macDeviceID: selectedMacDeviceID)
            dismiss()
        case .failure(let failure):
            failureText = failureMessage(failure)
        }
    }

    private func addTemplate(_ template: MobileTaskTemplate) {
        store.taskTemplateStore?.addTemplate(template)
        selectedTemplateID = template.id
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
        templates = store.taskTemplateStore?.listTemplates() ?? []
        if let selectedTemplateID, templates.contains(where: { $0.id == selectedTemplateID }) {
            return
        }
        selectedTemplateID = templates.first?.id
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
