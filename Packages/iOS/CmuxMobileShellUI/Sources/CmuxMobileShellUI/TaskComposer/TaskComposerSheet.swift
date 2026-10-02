#if os(iOS)
import CmuxMobilePairedMac
import CmuxMobileRPC
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSupport
import PhotosUI
import SwiftUI
import UIKit

struct TaskComposerSheet: View {
    @Environment(\.dismiss) var dismiss
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(MobileDisplaySettings.self) var displaySettings
    @Bindable var store: CMUXMobileShellStore

    @State var prompt = ""
    @State var workspaceName = ""
    @State private var templates: [MobileTaskTemplate]
    @State var selectedTemplateID: MobileTaskTemplate.ID?
    @State var selectedModelID: String?
    @State var selectedMacDeviceID: String
    @State var selectedMacInstanceTag: String?
    @State var directory: String
    @State var didEditDirectory = false
    @State var submissionPhase: TaskComposerSubmissionPhase = .idle
    @State var submitTask: Task<Void, Never>?
    @State var failureText: String?
    @State var failureTitleStyle: TaskComposerFailureTitleStyle = .launchFailed
    @State private var isEditorPresented = false
    @State var isDirectoryPickerPresented = false
    @State var shouldPersistDraftOnDisappear = true
    @State var submissionIdentity: MobileTaskSubmissionIdentity
    @State private var activeSubmissionSnapshot: MobileTaskSubmissionSnapshot?
    @State var completedOperationRecovery: TaskComposerCompletedOperationRecovery?
    @State var isStartAgainConfirmationPresented = false
    @State var attachments: [TaskComposerAttachment] = []
    @State var isAttachmentPhotoPickerPresented = false
    @State var attachmentPhotoSelection: [PhotosPickerItem] = []
    @State var isAttachmentFileImporterPresented = false
    @State var attachmentStagingTask: Task<Void, Never>?
    @State var attachmentAlertMessage: String?

    let sessionGeneration: Int
    private let availableMachines: [MobilePairedMac]?
    let submitTaskComposer: @MainActor (
        _ macDeviceID: String,
        _ instanceTag: String?,
        _ spec: MobileWorkspaceCreateSpec,
        _ willStartCreate: @escaping @MainActor () -> Void
    ) async -> Result<Void, MobileWorkspaceMutationFailure>
    private let searchTaskDirectories: (@MainActor (
        _ macDeviceID: String,
        _ instanceTag: String?,
        _ query: String
    ) async -> Result<MobileTaskDirectorySearchResponse, MobileTaskDirectorySearchFailure>)?
    private let listTaskDirectories: (@MainActor (
        _ macDeviceID: String,
        _ instanceTag: String?,
        _ path: String,
        _ offset: Int
    ) async -> Result<MobileTaskDirectoryListResponse, MobileTaskDirectoryListFailure>)?

    init(
        store: CMUXMobileShellStore,
        availableMachines: [MobilePairedMac]? = nil,
        submitTaskComposer: (@MainActor (
            _ macDeviceID: String,
            _ instanceTag: String?,
            _ spec: MobileWorkspaceCreateSpec,
            _ willStartCreate: @escaping @MainActor () -> Void
        ) async -> Result<Void, MobileWorkspaceMutationFailure>)? = nil,
        searchTaskDirectories: (@MainActor (
            _ macDeviceID: String,
            _ instanceTag: String?,
            _ query: String
        ) async -> Result<MobileTaskDirectorySearchResponse, MobileTaskDirectorySearchFailure>)? = nil,
        listTaskDirectories: (@MainActor (
            _ macDeviceID: String,
            _ instanceTag: String?,
            _ path: String,
            _ offset: Int
        ) async -> Result<MobileTaskDirectoryListResponse, MobileTaskDirectoryListFailure>)? = nil
    ) {
        self.store = store
        self.availableMachines = availableMachines
        self.sessionGeneration = store.currentSessionGeneration
        self.searchTaskDirectories = searchTaskDirectories
        self.listTaskDirectories = listTaskDirectories
        self.submitTaskComposer = submitTaskComposer ?? {
            macDeviceID,
            instanceTag,
            spec,
            willStartCreate in
            await store.submitTaskComposer(
                macDeviceID: macDeviceID,
                instanceTag: instanceTag,
                spec: spec,
                willStartCreate: willStartCreate
            )
        }
        let loadedTemplates = store.taskTemplateStore?.listTemplates() ?? []
        let templates = loadedTemplates
        let draft = store.taskTemplateStore?.composerDraft()
        let foregroundMacID = store.connectedMacDeviceID
        // Restore persisted Mac IDs only while they remain paired.
        let availablePairedMacs = availableMachines ?? store.displayPairedMacs
        let pairedMacIDs = availablePairedMacs.map(\.macDeviceID)
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
        // A draft that named a specific paired build restores that exact
        // pairing; otherwise prefer the active pairing for the device.
        let draftInstanceTag = draftMacID != nil ? draft?.macInstanceTag : nil
        let selectedMac = draftInstanceTag.flatMap { tag in
            availablePairedMacs.first {
                $0.macDeviceID == selectedMacID && $0.instanceTag == tag
            }
        } ?? availablePairedMacs.first {
            $0.macDeviceID == selectedMacID && $0.isActive
        } ?? availablePairedMacs.first {
            $0.macDeviceID == selectedMacID
        }
        let draftTemplateID = draft?.templateID
            .flatMap { id in templates.contains(where: { $0.id == id }) ? id : nil }
        let selectedTemplateID = draftTemplateID
            ?? store.taskTemplateStore?.lastTemplateID()
            .flatMap { id in templates.contains(where: { $0.id == id }) ? id : nil }
            ?? templates.first?.id
        let selectedTemplate = selectedTemplateID.flatMap { id in templates.first { $0.id == id } }
        let initialProvider = selectedTemplate.flatMap {
            MobileTaskAgentProvider(command: $0.command)
        }
        let initialDiscoveredModels = initialProvider.flatMap {
            store.discoveredTaskModels(
                provider: $0,
                macDeviceID: selectedMacID,
                instanceTag: selectedMac?.instanceTag
            )
        }
        let initialModelAvailability = MobileTaskModelAvailability(
            template: selectedTemplate,
            discoveredModels: initialDiscoveredModels
        )
        let initialModelID = (draft?.templateID == selectedTemplateID)
            ? initialModelAvailability.validatedModelID(draft?.modelID)
            : nil
        let openDirectory = Self.preferredOpenDirectory(
            workspaces: store.workspaces,
            selectedWorkspaceID: store.selectedWorkspaceID,
            macDeviceID: selectedMacID,
            connectedMacDeviceID: store.connectedMacDeviceID
        )
        let canRestoreDraftDirectory = draft != nil && (
            draft?.didEditDirectory == true
                || (draft?.templateID == selectedTemplateID && draft?.macDeviceID == selectedMacID)
        )
        let initialDirectory = canRestoreDraftDirectory
            ? draft?.directory ?? "~"
            : Self.suggestedDirectory(
                template: selectedTemplate,
                macDeviceID: selectedMacID,
                templateStore: store.taskTemplateStore,
                openDirectory: openDirectory
            )
        // A draft model that fails the cached effective-list validation changes the request
        // bytes, so its operation ID (and any recovery bound to it) must not
        // be reused for the resulting default-model command.
        let draftModelSurvivedValidation = draft?.modelID == nil || initialModelID != nil
        let restoredOperationID = (
            draft?.templateID == selectedTemplateID
                && draft?.macDeviceID == (selectedMacID.isEmpty ? nil : selectedMacID)
                && canRestoreDraftDirectory
                && draftModelSurvivedValidation
        ) ? draft?.operationID : nil
        let initialPrompt = draft?.prompt ?? ""
        let initialWorkspaceName = draft?.workspaceName ?? ""
        let initialOperationID = restoredOperationID ?? UUID()
        let initialRequest = selectedTemplate.map {
            MobileTaskSubmissionSnapshot(
                template: $0,
                prompt: initialPrompt,
                modelID: initialModelID,
                macDeviceID: selectedMacID,
                macInstanceTag: selectedMac?.instanceTag,
                directory: initialDirectory,
                workspaceName: initialWorkspaceName,
                didEditDirectory: canRestoreDraftDirectory && draft?.didEditDirectory == true,
                operationID: initialOperationID
            )
        }
        let canRestoreCompletedOperation = draft?.templateID == selectedTemplateID
            && draft?.macDeviceID == (selectedMacID.isEmpty ? nil : selectedMacID)
            && canRestoreDraftDirectory
            && draftModelSurvivedValidation
        let initialCompletedOperationRecovery = (canRestoreCompletedOperation
            ? draft?.completedOperationID
            : nil)
            .flatMap { operationID in
                initialRequest?.withOperationID(operationID)
            }
        _prompt = State(initialValue: initialPrompt)
        _workspaceName = State(initialValue: initialWorkspaceName)
        _templates = State(initialValue: templates)
        _selectedTemplateID = State(initialValue: selectedTemplateID)
        _selectedModelID = State(initialValue: initialModelID)
        _selectedMacDeviceID = State(initialValue: selectedMacID)
        _selectedMacInstanceTag = State(initialValue: selectedMac?.instanceTag)
        _directory = State(initialValue: initialDirectory)
        _didEditDirectory = State(initialValue: canRestoreDraftDirectory && draft?.didEditDirectory == true)
        _submissionIdentity = State(initialValue: MobileTaskSubmissionIdentity(
            id: initialOperationID,
            initialRequest: initialRequest
        ))
        _completedOperationRecovery = State(
            initialValue: initialCompletedOperationRecovery.map {
                TaskComposerCompletedOperationRecovery(submittedSnapshot: $0)
            }
        )
        _failureText = State(
            initialValue: initialCompletedOperationRecovery == nil
                ? nil
                : Self.failureMessage(.alreadyCompleted(hostDisplayName: nil))
        )
        _failureTitleStyle = State(
            initialValue: initialCompletedOperationRecovery == nil ? .launchFailed : .taskAccepted
        )
    }

    var body: some View {
        NavigationStack {
            Group {
                switch displaySettings.taskComposerLayoutStyle.renderedStyle {
                case .classic:
                    classicLayout
                case .composer:
                    minimalLayout
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
            .sheet(isPresented: $isDirectoryPickerPresented) {
                TaskComposerDirectoryPickerView(
                    candidates: directoryCandidates,
                    selectedPath: directory,
                    select: selectDirectory,
                    searchMac: resolvedSearchTaskDirectories,
                    listMac: resolvedListTaskDirectories
                )
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
            .onDisappear {
                // Parent-driven dismissal must cancel result application.
                submitTask?.cancel()
                attachmentStagingTask?.cancel()
                removeStagedAttachmentFiles()
                if shouldPersistDraftOnDisappear {
                    persistDraft()
                }
            }
            .onChange(of: scenePhase) { _, newPhase in
                guard newPhase != .active else { return }
                persistDraft()
            }
            .onChange(of: machines.map(\.id)) { _, _ in
                validateMacSelection()
            }
            .task(id: modelRefreshID) {
                guard let provider = modelRefreshID.provider,
                      !selectedMacDeviceID.isEmpty else { return }
                await store.refreshTaskModels(
                    provider: provider,
                    macDeviceID: selectedMacDeviceID,
                    instanceTag: selectedMacInstanceTag
                )
            }
            .modifier(TaskComposerStartAgainConfirmationModifier(
                isPresented: $isStartAgainConfirmationPresented,
                confirm: confirmStartAgain
            ))
            .modifier(TaskComposerAttachmentPickerModifier(
                isPhotoPickerPresented: $isAttachmentPhotoPickerPresented,
                photoSelection: $attachmentPhotoSelection,
                isFileImporterPresented: $isAttachmentFileImporterPresented,
                remainingCount: remainingAttachmentCount,
                selectedPhotos: stageSelectedPhotos,
                selectedFiles: stageSelectedFiles
            ))
            .alert(
                L10n.string(
                    "mobile.taskComposer.attachments.alert.title",
                    defaultValue: "Couldn’t Add Attachment"
                ),
                isPresented: Binding(
                    get: { attachmentAlertMessage != nil },
                    set: { isPresented in
                        if !isPresented {
                            attachmentAlertMessage = nil
                        }
                    }
                )
            ) {
                Button(L10n.string("mobile.common.ok", defaultValue: "OK")) {
                    attachmentAlertMessage = nil
                }
            } message: {
                Text(attachmentAlertMessage ?? "")
            }
        }
        .presentationDetents([.large])
        // Swipes inside the prompt belong to its scroll view. The drag
        // indicator remains the explicit affordance for moving or dismissing
        // the sheet, so the two vertical gestures no longer compete.
        .presentationContentInteraction(.scrolls)
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(submissionPhase.locksDismissal)
        .background(TaskComposerInitialFocusCoordinator(
            isEnabled: !submissionPhase.disablesRequestEditing
        ))
    }

    private var classicLayout: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground)
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 12) {
                    TaskComposerPromptCard(
                        prompt: promptBinding,
                        placeholder: promptPlaceholder,
                        isDisabled: submissionPhase.disablesRequestEditing,
                        endEditing: resolveCompletedOperationRecoveryAfterEditing,
                        templates: templates,
                        selectedTemplateID: selectedTemplateID,
                        modelPickerVariant: displaySettings.taskComposerModelPickerVariant,
                        models: availableModels,
                        selectedModelID: selectedModelID,
                        attachments: attachments,
                        showsAttachmentButton: showsAttachmentButton,
                        selectTemplate: selectTemplateFromPicker,
                        selectTemplateAndModel: selectTemplateAndModelFromPicker,
                        selectModel: selectModel,
                        editTemplates: presentTemplateEditor,
                        chooseAttachmentPhotos: presentAttachmentPhotoPicker,
                        chooseAttachmentFiles: presentAttachmentFileImporter,
                        removeAttachment: removeAttachment
                    )

                    TaskComposerContextSection(
                        workspaceName: workspaceNameBinding,
                        machines: machines,
                        selectedMacPairingID: selectedMacPairingID,
                        buildLabelsByID: machineBuildLabelsByID,
                        directory: directory,
                        modelPickerVariant: displaySettings.taskComposerModelPickerVariant,
                        models: availableModels,
                        selectedModelID: selectedModelID,
                        isDisabled: submissionPhase.disablesRequestEditing,
                        endWorkspaceNameEditing: resolveCompletedOperationRecoveryAfterEditing,
                        selectMachine: selectMachine,
                        selectDirectory: { isDirectoryPickerPresented = true },
                        selectModel: selectModel
                    )
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                }
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 20)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            TaskComposerPrimaryAction(
                isSubmitting: submissionPhase.showsProgress,
                isEnabled: selectedMachine != nil
                    && canLaunchSelectedTemplate
                    && attachmentStagingTask == nil,
                templateIcon: selectedTemplate?.icon,
                actionTitle: primaryActionTitle,
                progressTitle: primaryActionProgressTitle,
                caption: primaryActionCaption,
                failureTitle: failureTitleStyle.title,
                failureText: failureText,
                completedOperationRecovery: blockingCompletedOperationRecovery,
                action: startSubmission,
                refreshCompletedOperation: startCompletedOperationReconciliation,
                requestStartAgain: { isStartAgainConfirmationPresented = true }
            )
        }
        .navigationTitle(L10n.string("mobile.taskComposer.title", defaultValue: "New Task"))
        .mobileInlineNavigationTitle()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(action: cancelComposer) {
                    Image(systemName: "xmark")
                }
                // Cancellation remains safe while routing and capability
                // checks run. Lock only once the create boundary commits.
                .disabled(submissionPhase.locksDismissal)
                .accessibilityLabel(L10n.string("mobile.common.cancel", defaultValue: "Cancel"))
                .accessibilityIdentifier("MobileTaskComposerCancelButton")
            }
        }
    }

    private var minimalLayout: some View {
        TaskComposerMinimalLayout(
            prompt: promptBinding,
            genericPromptPlaceholder: promptPlaceholder,
            directory: directory,
            isDisabled: submissionPhase.disablesRequestEditing,
            locksDismissal: submissionPhase.locksDismissal,
            templates: templates,
            selectedTemplateID: selectedTemplateID,
            modelPickerVariant: displaySettings.taskComposerModelPickerVariant,
            models: availableModels,
            selectedModelID: selectedModelID,
            isSubmitting: submissionPhase.showsProgress,
            isSubmitEnabled: selectedMachine != nil
                && canLaunchSelectedTemplate
                && submissionPhase.allowsSubmission
                && attachmentStagingTask == nil
                && blockingCompletedOperationRecovery == nil,
            failureTitle: failureTitleStyle.title,
            failureText: failureText,
            completedOperationRecovery: blockingCompletedOperationRecovery,
            attachments: attachments,
            showsAttachmentButton: showsAttachmentButton,
            optionsSheet: { minimalOptionsSheet },
            endEditing: resolveCompletedOperationRecoveryAfterEditing,
            selectTemplate: selectTemplateFromPicker,
            selectTemplateAndModel: selectTemplateAndModelFromPicker,
            selectModel: selectModel,
            editTemplates: presentTemplateEditor,
            cancel: cancelComposer,
            submit: startSubmission,
            refreshCompletedOperation: startCompletedOperationReconciliation,
            requestStartAgain: { isStartAgainConfirmationPresented = true },
            chooseAttachmentPhotos: presentAttachmentPhotoPicker,
            chooseAttachmentFiles: presentAttachmentFileImporter,
            removeAttachment: removeAttachment
        )
    }

    private var minimalOptionsSheet: TaskComposerOptionsSheet {
        TaskComposerOptionsSheet(
            workspaceName: workspaceNameBinding,
            machines: machines,
            selectedMacPairingID: selectedMacPairingID,
            buildLabelsByID: machineBuildLabelsByID,
            directory: directory,
            // The composer layout's bottom-bar pill is the single model entry
            // point; the options sheet never repeats the contextRow variant.
            modelPickerVariant: .off,
            models: availableModels,
            selectedModelID: selectedModelID,
            isDisabled: submissionPhase.disablesRequestEditing,
            directoryCandidates: directoryCandidates,
            endWorkspaceNameEditing: resolveCompletedOperationRecoveryAfterEditing,
            selectMachine: selectMachine,
            selectDirectory: selectDirectory,
            selectModel: selectModel,
            searchMac: resolvedSearchTaskDirectories,
            listMac: resolvedListTaskDirectories
        )
    }

    private func resolvedSearchTaskDirectories(
        query: String
    ) async -> Result<MobileTaskDirectorySearchResponse, MobileTaskDirectorySearchFailure> {
        if let searchTaskDirectories {
            return await searchTaskDirectories(
                selectedMacDeviceID,
                selectedMacInstanceTag,
                query
            )
        }
        return await store.searchTaskDirectories(
            macDeviceID: selectedMacDeviceID,
            instanceTag: selectedMacInstanceTag,
            query: query
        )
    }

    private func resolvedListTaskDirectories(
        path: String,
        offset: Int
    ) async -> Result<MobileTaskDirectoryListResponse, MobileTaskDirectoryListFailure> {
        if let listTaskDirectories {
            return await listTaskDirectories(
                selectedMacDeviceID,
                selectedMacInstanceTag,
                path,
                offset
            )
        }
        return await store.listTaskDirectories(
            macDeviceID: selectedMacDeviceID,
            instanceTag: selectedMacInstanceTag,
            path: path,
            offset: offset
        )
    }

    var selectedTemplate: MobileTaskTemplate? {
        selectedTemplateID.flatMap { id in templates.first { $0.id == id } }
    }

    private var machines: [MobilePairedMac] {
        availableMachines ?? store.displayPairedMacs
    }

    var selectedMachine: MobilePairedMac? {
        machines.first {
            $0.macDeviceID == selectedMacDeviceID
                && $0.instanceTag == selectedMacInstanceTag
        }
    }

    private var selectedMacPairingID: String {
        MobilePairedMac.pairingID(
            macDeviceID: selectedMacDeviceID,
            instanceTag: selectedMacInstanceTag
        )
    }

    private var modelRefreshID: TaskComposerModelRefreshID {
        TaskComposerModelRefreshID(
            provider: selectedTemplate.flatMap {
                MobileTaskAgentProvider(command: $0.command)
            },
            macPairingID: selectedMacPairingID
        )
    }

    private var machineBuildLabelsByID: [String: String] {
        var labels: [String: String] = [:]
        for mac in machines {
            labels[mac.id] = store.presenceSummary(
                for: mac.macDeviceID,
                instanceTag: mac.instanceTag
            )?.buildLabel ?? MacBuildChannel().label(bundleID: nil, tag: mac.instanceTag)
        }
        return labels
    }

    private var canLaunchSelectedTemplate: Bool {
        guard let selectedTemplate else { return false }
        return selectedTemplate.isPlainShell
            || !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var promptPlaceholder: String {
        guard let selectedTemplate else {
            return L10n.string(
                "mobile.taskComposer.promptPlaceholder",
                defaultValue: "Describe what you want to accomplish"
            )
        }
        if selectedTemplate.isPlainShell {
            return L10n.string(
                "mobile.taskComposer.promptPlaceholder.shell",
                defaultValue: "Describe what you want to run"
            )
        }
        return String(
            format: L10n.string(
                "mobile.taskComposer.promptPlaceholder.agentFormat",
                defaultValue: "Tell %@ what to build, fix, or investigate"
            ),
            selectedTemplate.name
        )
    }

    private var primaryActionTitle: String {
        if submissionPhase.offersRetry {
            return L10n.string(
                "mobile.taskComposer.tryAgain",
                defaultValue: "Try Again"
            )
        }
        guard let selectedTemplate else {
            return L10n.string("mobile.taskComposer.startTask", defaultValue: "Start Task")
        }
        if selectedTemplate.isPlainShell {
            return L10n.string("mobile.taskComposer.openShell", defaultValue: "Open Shell")
        }
        return String(
            format: L10n.string(
                "mobile.taskComposer.startAgentFormat",
                defaultValue: "Start %@"
            ),
            selectedTemplate.name
        )
    }

    private var primaryActionProgressTitle: String {
        if submissionPhase == .preparing {
            return L10n.string(
                "mobile.taskComposer.preparingWorkspace",
                defaultValue: "Preparing workspace…"
            )
        }
        guard let selectedTemplate else {
            return L10n.string("mobile.taskComposer.startingTask", defaultValue: "Starting Task…")
        }
        if selectedTemplate.isPlainShell {
            return L10n.string("mobile.taskComposer.openingShell", defaultValue: "Opening Shell…")
        }
        return String(
            format: L10n.string(
                "mobile.taskComposer.startingAgentFormat",
                defaultValue: "Starting %@…"
            ),
            selectedTemplate.name
        )
    }

    private var primaryActionCaption: String {
        guard let selectedTemplate else {
            return L10n.string(
                "mobile.taskComposer.action.caption",
                defaultValue: "Creates a workspace and sends your prompt immediately."
            )
        }
        if !selectedTemplate.isPlainShell, !canLaunchSelectedTemplate {
            return String(
                format: L10n.string(
                    "mobile.taskComposer.action.promptRequiredFormat",
                    defaultValue: "Add a prompt to put %@ to work."
                ),
                selectedTemplate.name
            )
        }
        guard let selectedMachine else {
            return L10n.string(
                "mobile.taskComposer.action.caption",
                defaultValue: "Creates a workspace and sends your prompt immediately."
            )
        }
        return String(
            format: L10n.string(
                "mobile.taskComposer.action.routeCaptionFormat",
                defaultValue: "New workspace on %@ in %@."
            ),
            selectedMachine.resolvedName,
            TaskComposerDirectoryDisplayPath(path: directory).name
        )
    }

    private var promptBinding: Binding<String> {
        Binding(
            get: { prompt },
            set: { newValue in
                guard !submissionPhase.disablesRequestEditing else { return }
                updateSubmissionRequest {
                    prompt = newValue
                }
            }
        )
    }

    private var workspaceNameBinding: Binding<String> {
        Binding(
            get: { workspaceName },
            set: { newValue in
                guard !submissionPhase.disablesRequestEditing else { return }
                updateSubmissionRequest {
                    workspaceName = newValue
                }
            }
        )
    }

    private func selectTemplateFromPicker(_ id: MobileTaskTemplate.ID) {
        selectTemplateAndModelFromPicker(id, nil)
    }

    private func selectTemplateAndModelFromPicker(_ id: MobileTaskTemplate.ID, _ modelID: String?) {
        guard !submissionPhase.disablesRequestEditing,
              let template = templates.first(where: { $0.id == id }) else { return }
        withAnimation(accessibilityReduceMotion ? nil : .snappy(duration: 0.2)) {
            selectTemplate(template, modelID: modelID)
        }
    }

    private func presentTemplateEditor() {
        persistDraft()
        isEditorPresented = true
    }

    private func cancelComposer() {
        submitTask?.cancel()
        shouldPersistDraftOnDisappear = false
        store.clearTaskComposerDraft(ifSessionGeneration: sessionGeneration)
        dismiss()
    }

    private func selectMachine(_ macDeviceID: String, _ instanceTag: String?) {
        guard !submissionPhase.disablesRequestEditing,
              machines.contains(where: {
                  $0.macDeviceID == macDeviceID && $0.instanceTag == instanceTag
              }) else { return }
        updateSubmissionRequest(reconcileRecovery: true) {
            selectedMacDeviceID = macDeviceID
            selectedMacInstanceTag = instanceTag
            syncSuggestedDirectory()
        }
    }

    func startSubmission() {
        resolveCompletedOperationRecoveryAfterEditing()
        guard submitTask == nil,
              attachmentStagingTask == nil,
              blockingCompletedOperationRecovery == nil,
              submissionPhase.allowsSubmission else { return }
        // Once the user sends a genuinely different request, the prior
        // recovery anchor can no longer become relevant through further edits.
        completedOperationRecovery = nil
        if submissionPhase.offersRetry {
            failureText = nil
        }
        submitTask = Task { @MainActor in
            await submit()
            submitTask = nil
        }
    }

    private func submit() async {
        guard submissionPhase.allowsSubmission,
              let snapshot = submissionSnapshot() else { return }
        guard store.persistTaskComposerDraft(
            snapshot.draft,
            ifSessionGeneration: sessionGeneration
        ) else {
            failureTitleStyle = .launchFailed
            let message = Self.draftPersistenceFailureMessage
            failureText = message
            announceFailure(message)
            return
        }
        submissionPhase = .preparing
        activeSubmissionSnapshot = snapshot
        failureText = nil
        let attachmentPaths: [String]
        switch await uploadAttachments(for: snapshot) {
        case .success(let paths):
            attachmentPaths = paths
        case .failure(let failure):
            submissionPhase = .idle
            activeSubmissionSnapshot = nil
            guard !Task.isCancelled else { return }
            restoreSubmittedDraft(snapshot)
            _ = store.persistTaskComposerDraft(
                snapshot.draft,
                ifSessionGeneration: sessionGeneration
            )
            submissionPhase = .retryReady
            failureTitleStyle = .launchFailed
            let message = Self.attachmentUploadFailureMessage(failure)
            failureText = message
            announceFailure(message)
            return
        }
        guard !Task.isCancelled else {
            submissionPhase = .idle
            activeSubmissionSnapshot = nil
            return
        }
        let spec = workspaceCreateSpec(
            for: snapshot,
            attachmentPaths: attachmentPaths
        )
        let result = await submitTaskComposer(
            snapshot.macDeviceID,
            snapshot.macInstanceTag,
            spec
        ) {
            submissionPhase = .committed
        }
        submissionPhase = .idle
        activeSubmissionSnapshot = nil
        // The user dismissed the sheet mid-flight: drop the result instead of
        // persisting last-used defaults or re-dismissing a gone sheet.
        guard !Task.isCancelled else { return }
        switch result {
        case .success:
            completeSubmission(snapshot)
        case .failure(let failure):
            restoreSubmittedDraft(snapshot)
            if case .alreadyCompleted = failure {
                completedOperationRecovery = TaskComposerCompletedOperationRecovery(
                    submittedSnapshot: snapshot
                )
                // Retire the host tombstone immediately. A relaunch preserves
                // this same draft with a fresh ID, but UI recovery still gates
                // sending it until refresh and explicit confirmation.
                submissionIdentity.rotate()
                _ = store.persistTaskComposerDraft(
                    draftSnapshot(),
                    ifSessionGeneration: sessionGeneration
                )
            } else {
                _ = store.persistTaskComposerDraft(
                    snapshot.draft,
                    ifSessionGeneration: sessionGeneration
                )
                submissionPhase = .retryReady
            }
            failureTitleStyle = TaskComposerFailureTitleStyle(failure: failure)
            let message = Self.failureMessage(failure)
            failureText = message
            announceFailure(message)
        }
    }

    private func addTemplate(_ template: MobileTaskTemplate) {
        guard !submissionPhase.disablesRequestEditing else { return }
        updateSubmissionRequest(reconcileRecovery: true) {
            store.taskTemplateStore?.addTemplate(template)
            selectedTemplateID = template.id
            selectedModelID = nil
            syncSuggestedDirectory()
        }
    }

    private func updateTemplate(_ template: MobileTaskTemplate) {
        guard !submissionPhase.disablesRequestEditing else { return }
        store.taskTemplateStore?.updateTemplate(template)
    }

    private func deleteTemplates(_ offsets: IndexSet) {
        guard !submissionPhase.disablesRequestEditing else { return }
        let ids = Set(offsets.map { templates[$0].id })
        store.taskTemplateStore?.deleteTemplates(ids: ids)
    }

    private func refreshTemplates() {
        guard !submissionPhase.disablesRequestEditing else { return }
        updateSubmissionRequest(reconcileRecovery: true) {
            templates = store.taskTemplateStore?.listTemplates() ?? []
            if let selectedTemplateID, !templates.contains(where: { $0.id == selectedTemplateID }) {
                self.selectedTemplateID = templates.first?.id
            }
            selectedModelID = selectedModel?.id
            // Sync template edits unless the user typed the directory.
            syncSuggestedDirectory()
        }
    }

    private func validateMacSelection() {
        guard !submissionPhase.disablesRequestEditing else { return }
        guard selectedMachine == nil else { return }
        updateSubmissionRequest(reconcileRecovery: true) {
            selectedMacDeviceID = machines.first?.macDeviceID ?? ""
            selectedMacInstanceTag = machines.first?.instanceTag
            syncSuggestedDirectory()
        }
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

}
#endif
