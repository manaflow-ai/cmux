#if os(iOS)
import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileRPC
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSupport
import PhotosUI
import SwiftUI

struct TaskComposerSheet: View {
    @Environment(\.dismiss) var dismiss
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Bindable var store: CMUXMobileShellStore

    @State var prompt = ""
    @State var workspaceName = ""
    @State private var templates: [MobileTaskTemplate]
    @State var selectedTemplateID: MobileTaskTemplate.ID?
    @State var selectedModelID: String?
    @State var explicitlySelectedModel: MobileTaskAgentModel?
    @State var selectedEffortID: String?
    @State var selectedMacDeviceID: String
    @State var selectedMacInstanceTag: String?
    @State var selectedWorkspaceGroupID: MobileWorkspaceGroupPreview.ID?
    // A persisted group can be restored before the live host inventory arrives.
    // Keep it separate from an explicit user selection so an empty first
    // projection cannot silently turn a grouped task into an ungrouped one.
    @State var pendingRestoredWorkspaceGroupID: MobileWorkspaceGroupPreview.ID?
    @State var workspaceGroupSelectionRequiresResolution = false
    @State private var modelRefreshTask: Task<Void, Never>?
    @State private var modelRefreshOperationID: UUID?
    @State private var isModelLoadingIndicatorVisible = false
    @State var displayedModels: [MobileTaskAgentModel]
    @State var displayedDefaultModel: MobileTaskAgentModel?
    @State var displayedModelError: MobileTaskModelListError?
    @State var directory: String
    @State var didEditDirectory = false
    @State var submissionPhase: TaskComposerSubmissionPhase = .idle
    @State var submitTask: Task<Void, Never>?
    @State var failureText: String?
    @State var failureTitleStyle: TaskComposerFailureTitleStyle = .launchFailed
    @State private var isEditorPresented = false
    @State var shouldPersistDraftOnDisappear = true
    @State var submissionIdentity: MobileTaskSubmissionIdentity
    @State private var activeSubmissionSnapshot: MobileTaskSubmissionSnapshot?
    @State var completedOperationRecovery: TaskComposerCompletedOperationRecovery?
    @State var isStartAgainConfirmationPresented = false
    @State var attachments: [TaskComposerAttachment]
    @State var isAttachmentPhotoPickerPresented = false
    @State var attachmentPhotoSelection: [PhotosPickerItem] = []
    @State var isAttachmentFileImporterPresented = false
    @State var attachmentStagingTask: Task<Void, Never>?
    /// Monotonic batch token: each staging batch bumps it, and a finishing
    /// batch clears ``attachmentStagingTask`` only when its own token is still
    /// current, so a stale (cancelled) batch cannot drop a newer batch's handle.
    @State var attachmentStagingGeneration = 0
    @State var attachmentAlertMessage: String?
    /// Draft typing is sampled once per composer presentation so this bounded
    /// log records that editing occurred without one event per keystroke.
    @State var hasRecordedDraftChange = false
    @State private var isDraftsListPresented = false
    @State var isLeaveConfirmationPresented = false
    /// Whether the user explicitly picked a model or effort this session.
    /// Tracked as an action, not by comparing values: catalog refreshes
    /// auto-reconcile those pickers, and an automatic adjustment must not
    /// prompt to save on leave, while a deliberate pick must.
    @State var hasUserPickedModelOrEffort = false
    /// True until this session's preserved attachments finish re-staging, so
    /// an early leave still persists their references instead of dropping
    /// them with the not-yet-populated live list.
    @State var isDraftAttachmentRestorePending: Bool

    let sessionGeneration: Int
    /// Stable identity of this session's saved-draft entry. Every leave,
    /// retry, and submit updates or removes exactly this entry. State, not a
    /// stored `let`: the host re-evaluates this view's init on unrelated
    /// re-renders (connection churn), and a fresh session must not mint a
    /// new identity per evaluation or consecutive saves split into
    /// duplicate draft entries.
    @State var draftID: UUID
    /// Replaces this editing session with another draft's. `nil` hides the
    /// drafts affordance for hosts without a session presenter (previews and
    /// accessibility harnesses).
    private let onSwitchDraft: ((TaskComposerLaunchIntent) -> Void)?
    /// Attachment references preserved with the resumed draft; re-staged
    /// into session-owned temporary copies on appear. State for the same
    /// re-evaluation stability as `draftID`.
    @State var restoredDraftAttachments: [MobileTaskComposerDraftAttachment]
    /// Leave-relevant state as this session opened; leaving with anything
    /// different asks before discarding. State so a mid-session save cannot
    /// move the baseline on re-evaluation.
    @State var initialSessionFingerprint: TaskComposerSessionFingerprint
    private let restoredDraftAtInitialization: Bool
    private let availableMachines: [MobilePairedMac]?
    private let availableWorkspaceGroups: [MobileWorkspaceGroupPreview]?
    private let modelLoadingIndicatorClock: any Clock<Duration>
    let taskAttachmentsCapabilityOverride: Bool?
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
        launchIntent: TaskComposerLaunchIntent = .new,
        onSwitchDraft: ((TaskComposerLaunchIntent) -> Void)? = nil,
        availableMachines: [MobilePairedMac]? = nil,
        availableWorkspaceGroups: [MobileWorkspaceGroupPreview]? = nil,
        taskAttachmentsCapabilityOverride: Bool? = nil,
        initialAttachments: [TaskComposerAttachment] = [],
        modelLoadingIndicatorClock: any Clock<Duration> = ContinuousClock(),
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
        self.availableWorkspaceGroups = availableWorkspaceGroups
        self.modelLoadingIndicatorClock = modelLoadingIndicatorClock
        self.taskAttachmentsCapabilityOverride = taskAttachmentsCapabilityOverride
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
        self.onSwitchDraft = onSwitchDraft
        let loadedTemplates = store.taskTemplateStore?.listTemplates() ?? []
        let templates = loadedTemplates
        let savedDrafts = store.taskTemplateStore?.composerDrafts() ?? []
        let resumedDraft = launchIntent.resolveDraft(in: savedDrafts)
        let draft = resumedDraft?.content
        _draftID = State(initialValue: resumedDraft?.id ?? UUID())
        self.restoredDraftAtInitialization = draft != nil
        let foregroundMacID = store.connectedMacDeviceID
        let foregroundMacInstanceTag = store.connectedMacInstanceTag
        // Restore persisted Mac IDs only while they remain paired.
        let availablePairedMacs = availableMachines ?? store.displayPairedMacs
        let restoredMac = store.taskTemplateStore?.lastMacDeviceID()
            .flatMap { id in availablePairedMacs.first { $0.id == id } }
        // Restore a draft only when its complete pairing identity still exists.
        // A device-only legacy draft cannot select an arbitrary Stable/Nightly
        // sibling that happens to sort first.
        let draftMac = draft?.macDeviceID.flatMap { draftMacDeviceID in
            availablePairedMacs.first {
                $0.id == MobilePairedMac.pairingID(
                    macDeviceID: draftMacDeviceID,
                    instanceTag: draft?.macInstanceTag
                )
            }
        }
        // The authenticated foreground identity outranks a possibly stale
        // persisted active flag.
        let foregroundMac = availablePairedMacs.first {
            $0.id == MobilePairedMac.pairingID(
                macDeviceID: foregroundMacID ?? "",
                instanceTag: foregroundMacInstanceTag
            )
        }
        let selectedMac = draftMac
            ?? restoredMac
            ?? foregroundMac
            ?? availablePairedMacs.first(where: \.isActive)
            ?? availablePairedMacs.first
        let selectedMacID = selectedMac?.macDeviceID ?? foregroundMacID ?? ""
        let selectedMacInstanceTag: String?
        if let selectedMac {
            selectedMacInstanceTag = selectedMac.instanceTag
        } else {
            selectedMacInstanceTag = selectedMacID == foregroundMacID
                ? foregroundMacInstanceTag
                : nil
        }
        let draftMatchesSelectedMac = draft == nil || draft.map {
            MobilePairedMac.pairingID(
                macDeviceID: $0.macDeviceID ?? "",
                instanceTag: $0.macInstanceTag
            ) == MobilePairedMac.pairingID(
                macDeviceID: selectedMacID,
                instanceTag: selectedMacInstanceTag
            )
        } == true
        // Keep a restored group ID until the live inventory proves whether it
        // still exists. The workspace/group projection is populated after the
        // sheet can be initialized, so an empty snapshot here means
        // "not loaded yet", not "definitively ungrouped".
        let initialWorkspaceGroupID = draft?.workspaceGroupID
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
        let initialModelResult = initialProvider.flatMap {
            store.discoveredTaskModelResult(
                provider: $0,
                macDeviceID: selectedMacID,
                instanceTag: selectedMacInstanceTag
            )
        }
        let initialModelAvailability = MobileTaskModelAvailability(
            template: selectedTemplate,
            discoveredModels: initialModelResult?.models,
            defaultModel: initialModelResult?.defaultModel
        )
        // A model persisted by this composer was already validated when the
        // user selected it. Preserve that explicit choice across a cold cache
        // or later delisting instead of changing the request while discovery
        // is still loading.
        let restoredDraftModelID = (draft?.templateID == selectedTemplateID)
            ? draft?.modelID
            : nil
        let initialModelID = initialModelAvailability.validatedModelID(
            restoredDraftModelID,
            previouslyValidModelID: restoredDraftModelID
        )
        let initialSelectedModel = initialModelAvailability.models.first {
            $0.id == initialModelID
        }
        let restoredDraftEffortID = (draft?.modelID == initialModelID)
            ? draft?.effortID
            : nil
        let initialEffortModel = initialSelectedModel ?? initialModelAvailability.defaultModel
        let initialEffortID = initialEffortModel.flatMap { model in
            model.efforts.contains { $0.id == restoredDraftEffortID }
                ? restoredDraftEffortID
                : model.defaultEffortID
        }
        let openDirectory = Self.preferredOpenDirectory(
            workspaces: store.workspaces,
            selectedWorkspaceID: store.selectedWorkspaceID,
            macDeviceID: selectedMacID,
            connectedMacDeviceID: store.connectedMacDeviceID,
            instanceTag: selectedMacInstanceTag,
            connectedMacInstanceTag: store.connectedMacInstanceTag
        )
        let canRestoreDraftDirectory = draft != nil && (
            draft?.didEditDirectory == true
                || (draft?.templateID == selectedTemplateID && draftMatchesSelectedMac)
        )
        let initialDirectory = canRestoreDraftDirectory
            ? draft?.directory ?? "~"
            : Self.suggestedDirectory(
                template: selectedTemplate,
                macDeviceID: selectedMacID,
                instanceTag: selectedMacInstanceTag,
                templateStore: store.taskTemplateStore,
                openDirectory: openDirectory
            )
        // A draft model that fails the cached effective-list validation changes the request
        // bytes, so its operation ID (and any recovery bound to it) must not
        // be reused for the resulting default-model command.
        let draftModelSurvivedValidation = draft?.modelID == nil || initialModelID != nil
        let draftEffortSurvivedValidation = draft?.effortID == initialEffortID
        let restoredOperationID = (
            draft?.templateID == selectedTemplateID
                && draftMatchesSelectedMac
                && draft?.workspaceGroupID == initialWorkspaceGroupID
                && canRestoreDraftDirectory
                && draftModelSurvivedValidation
                && draftEffortSurvivedValidation
        ) ? draft?.operationID : nil
        let initialPrompt = draft?.prompt ?? ""
        let initialWorkspaceName = draft?.workspaceName ?? ""
        let initialOperationID = restoredOperationID ?? UUID()
        let restoredAttachments = draft?.attachments ?? []
        // The restored attachment identities are part of the request the
        // operation ID belongs to; without them the async attachment restore
        // would look like an edit and rotate a still-valid retry identity.
        let initialRequest = selectedTemplate.map {
            MobileTaskSubmissionSnapshot(
                template: $0,
                prompt: initialPrompt,
                modelID: initialModelID,
                effortID: initialEffortID,
                macDeviceID: selectedMacID,
                macInstanceTag: selectedMacInstanceTag,
                directory: initialDirectory,
                workspaceName: initialWorkspaceName,
                workspaceGroupID: initialWorkspaceGroupID,
                didEditDirectory: canRestoreDraftDirectory && draft?.didEditDirectory == true,
                attachments: restoredAttachments.map {
                    MobileTaskSubmissionAttachment(uploadID: $0.id, byteCount: $0.byteCount)
                },
                operationID: initialOperationID
            )
        }
        _restoredDraftAttachments = State(initialValue: restoredAttachments)
        _isDraftAttachmentRestorePending = State(initialValue: !restoredAttachments.isEmpty)
        _initialSessionFingerprint = State(initialValue: TaskComposerSessionFingerprint(
            prompt: initialPrompt,
            workspaceName: initialWorkspaceName,
            templateID: selectedTemplateID,
            macPairingID: MobilePairedMac.pairingID(
                macDeviceID: selectedMacID,
                instanceTag: selectedMacInstanceTag
            ),
            directory: initialDirectory,
            didEditDirectory: canRestoreDraftDirectory && draft?.didEditDirectory == true,
            workspaceGroupID: initialWorkspaceGroupID,
            attachmentIDs: Set(initialAttachments.map(\.id))
                .union(restoredAttachments.map(\.id))
        ))
        let canRestoreCompletedOperation = draft?.templateID == selectedTemplateID
            && draftMatchesSelectedMac
            && draft?.workspaceGroupID == initialWorkspaceGroupID
            && canRestoreDraftDirectory
            && draftModelSurvivedValidation
            && draftEffortSurvivedValidation
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
        _explicitlySelectedModel = State(initialValue: initialModelAvailability.models.first {
            $0.id == initialModelID
        })
        _selectedEffortID = State(initialValue: initialEffortID)
        _selectedMacDeviceID = State(initialValue: selectedMacID)
        _selectedMacInstanceTag = State(initialValue: selectedMacInstanceTag)
        _selectedWorkspaceGroupID = State(initialValue: initialWorkspaceGroupID)
        _pendingRestoredWorkspaceGroupID = State(initialValue: draft?.workspaceGroupID)
        _displayedModels = State(initialValue: initialModelResult?.models ?? [])
        _displayedDefaultModel = State(initialValue: initialModelResult?.defaultModel)
        _displayedModelError = State(initialValue: initialModelResult?.error)
        _attachments = State(initialValue: initialAttachments)
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
            composerLayout
            .sheet(isPresented: $isEditorPresented) {
                TaskTemplateEditorView(
                    templates: templates,
                    addTemplate: addTemplate,
                    updateTemplate: updateTemplate,
                    deleteTemplates: deleteTemplates,
                    refresh: refreshTemplates
                )
            }
            .sheet(isPresented: $isDraftsListPresented) {
                TaskComposerDraftsSheet(
                    loadDrafts: { [store, draftID] in
                        store.taskComposerSavedDrafts().filter { $0.id != draftID }
                    },
                    templates: templates,
                    resume: resumeDraft,
                    startNew: startNewDraft,
                    delete: deleteDrafts
                )
            }
            .onDisappear {
                store.recordAppEvent(
                    .taskComposerClosed,
                    correlationID: submissionIdentity.id.uuidString
                )
                // Parent-driven dismissal must cancel result application.
                submitTask?.cancel()
                modelRefreshTask?.cancel()
                modelRefreshOperationID = nil
                attachmentStagingTask?.cancel()
                // Persist before deleting the staged files: preserving an
                // attachment copies from its staged URL, so the reverse order
                // silently drops attachments from the saved draft.
                if shouldPersistDraftOnDisappear {
                    persistDraft()
                }
                removeStagedAttachmentFiles()
            }
            .onAppear {
                store.recordAppEvent(
                    .taskComposerOpened,
                    correlationID: submissionIdentity.id.uuidString
                )
                store.recordAppEvent(
                    .taskTemplateListLoaded,
                    count: templates.count
                )
                validateWorkspaceGroupSelection()
                if restoredDraftAtInitialization {
                    store.recordAppEvent(.draftRestored)
                }
                restoreDraftAttachments()
            }
            .onChange(of: scenePhase) { _, newPhase in
                guard newPhase != .active else { return }
                persistDraft()
            }
            .onChange(of: machines.map(\.id)) { _, _ in
                validateMacSelection()
            }
            .onChange(of: workspaceGroupSelectionKey) { _, _ in
                validateWorkspaceGroupSelection()
            }
            .onChange(of: store.workspaceTopologyVersion) { _, _ in
                validateWorkspaceGroupSelection()
            }
            .onChange(of: canSelectWorkspaceGroup) { _, _ in
                validateWorkspaceGroupSelection()
            }
            .onChange(of: workspaceGroupInventoryIsAuthoritative) { _, _ in
                validateWorkspaceGroupSelection()
            }
            .onChange(of: submissionPhase) { _, _ in
                validateWorkspaceGroupSelection()
            }
            .modifier(TaskComposerStartAgainConfirmationModifier(
                isPresented: $isStartAgainConfirmationPresented,
                confirm: confirmStartAgain
            ))
            .alert(
                L10n.string(
                    "mobile.taskComposer.drafts.leaveDialog.title",
                    defaultValue: "Save this task as a draft?"
                ),
                isPresented: $isLeaveConfirmationPresented
            ) {
                Button(L10n.string(
                    "mobile.taskComposer.drafts.leaveDialog.save",
                    defaultValue: "Save Draft"
                )) {
                    saveDraftAndDismiss()
                }
                Button(
                    L10n.string(
                        "mobile.taskComposer.drafts.leaveDialog.delete",
                        defaultValue: "Delete Draft"
                    ),
                    role: .destructive
                ) {
                    deleteDraftAndDismiss()
                }
                Button(
                    L10n.string("mobile.common.cancel", defaultValue: "Cancel"),
                    role: .cancel
                ) {}
            }
            .modifier(TaskComposerAttachmentPickerModifier(
                isPhotoPickerPresented: $isAttachmentPhotoPickerPresented,
                photoSelection: $attachmentPhotoSelection,
                isFileImporterPresented: $isAttachmentFileImporterPresented,
                remainingCount: remainingAttachmentCount,
                selectedPhotos: stageSelectedPhotos,
                dismissedPhotos: {
                    store.recordAppEvent(.photoPickerDismissed)
                },
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
        // Provider/Mac changes replace ownership and cancel obsolete work.
        .onChange(of: modelRefreshID, initial: true) { _, _ in
            restartModelRefresh()
        }
        .task(id: isModelLoading) {
            await updateModelLoadingIndicator(isLoading: isModelLoading)
        }
    }

    private var composerLayout: some View {
        TaskComposerLayout(
            prompt: promptBinding,
            genericPromptPlaceholder: promptPlaceholder,
            workspaceName: workspaceName,
            directory: directory,
            isDisabled: submissionPhase.disablesRequestEditing,
            locksDismissal: submissionPhase.locksDismissal,
            templates: templates,
            selectedTemplateID: selectedTemplateID,
            models: availableModels,
            selectedModelID: selectedModelID,
            efforts: availableEfforts,
            selectedEffortID: selectedEffortID,
            modelErrorText: modelPickerErrorText,
            effortErrorText: effortPickerErrorText,
            agentErrorText: agentPickerErrorText,
            isModelLoading: isModelLoadingIndicatorVisible,
            isSubmitting: submissionPhase.showsProgress,
            isSubmitEnabled: selectedMachine != nil
                && canLaunchSelectedTemplate
                && submissionPhase.allowsSubmission
                && attachmentStagingTask == nil
                && !workspaceGroupSelectionNeedsInventory
                && !workspaceGroupSelectionRequiresResolution
                && blockingCompletedOperationRecovery == nil,
            connectionWarningText: connectionWarningText,
            failureTitle: failureTitleStyle.title,
            failureText: failureText,
            completedOperationRecovery: blockingCompletedOperationRecovery,
            attachments: attachments,
            showsAttachmentButton: showsAttachmentButton,
            optionsSheet: { optionsSheet },
            openDrafts: openDraftsAction,
            endEditing: resolveCompletedOperationRecoveryAfterEditing,
            selectTemplate: selectTemplateFromPicker,
            selectModel: selectModel,
            selectEffort: selectEffort,
            editTemplates: presentTemplateEditor,
            cancel: cancelComposer,
            submit: startSubmission,
            refreshCompletedOperation: startCompletedOperationReconciliation,
            requestStartAgain: { isStartAgainConfirmationPresented = true },
            chooseAttachmentPhotos: presentAttachmentPhotoPicker,
            chooseAttachmentFiles: presentAttachmentFileImporter,
            pasteAttachments: stagePasteboardAttachments,
            removeAttachment: removeAttachment
        )
    }

    private var optionsSheet: TaskComposerOptionsSheet {
        TaskComposerOptionsSheet(
            workspaceName: workspaceNameBinding,
            machines: machines,
            selectedMacPairingID: selectedMacPairingID,
            buildLabelsByID: machineBuildLabelsByID,
            workspaceGroups: workspaceGroupsForSelectedMachine,
            selectedWorkspaceGroupID: resolvedWorkspaceGroupID
                ?? pendingRestoredWorkspaceGroupID
                ?? selectedWorkspaceGroupID,
            workspaceGroupSelectionPending: workspaceGroupSelectionNeedsInventory,
            workspaceGroupSelectionRequiresResolution: workspaceGroupSelectionRequiresResolution,
            showsWorkspaceGroupPicker: canSelectWorkspaceGroup
                || workspaceGroupSelectionNeedsInventory
                || workspaceGroupSelectionRequiresResolution,
            directory: directory,
            isDisabled: submissionPhase.disablesRequestEditing,
            directoryCandidates: directoryCandidates,
            endWorkspaceNameEditing: resolveCompletedOperationRecoveryAfterEditing,
            selectMachine: selectMachine,
            selectWorkspaceGroup: selectWorkspaceGroup,
            selectDirectory: selectDirectory,
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

    /// The "No Mac is connected" notice. The entrypoint no longer hides while
    /// offline, so the composer itself must say why a task cannot start yet.
    /// The accessibility harness injects deterministic machines without live
    /// sessions, so injected machines suppress the warning.
    private var connectionWarningText: String? {
        guard availableMachines == nil, !store.hasAnyConnectedMac else { return nil }
        return L10n.string(
            "mobile.taskComposer.warning.noConnectedMac",
            defaultValue: "No Mac is connected. Open cmux on a Mac to start this task."
        )
    }

    private var workspaceGroups: [MobileWorkspaceGroupPreview] {
        guard canSelectWorkspaceGroup else { return [] }
        return availableWorkspaceGroups ?? store.workspaceGroups
    }

    private var canSelectWorkspaceGroup: Bool {
        // The accessibility harness injects deterministic groups without a
        // live host capability handshake. Production state must advertise the
        // create-in-group RPC on the selected Mac before exposing a control
        // that can send it.
        availableWorkspaceGroups != nil || workspaceCreateInGroupCapability == true
    }

    private var workspaceCreateInGroupCapability: Bool? {
        if availableWorkspaceGroups != nil {
            return true
        }
        return store.workspaceCreateInGroupCapability(
            macDeviceID: selectedMacDeviceID,
            instanceTag: selectedMacInstanceTag
        )
    }

    var workspaceGroupInventoryIsAuthoritative: Bool {
        if availableWorkspaceGroups != nil {
            return true
        }
        // A connected selected Mac that completed capability negotiation
        // without the group-create capability definitively cannot honor a
        // restored group.
        if workspaceCreateInGroupCapability == false {
            return true
        }
        return store.workspaceGroupInventoryIsAuthoritative(
            macDeviceID: selectedMacDeviceID,
            instanceTag: selectedMacInstanceTag
        )
    }

    var workspaceGroupSelectionNeedsInventory: Bool {
        selectedWorkspaceGroupID != nil && !workspaceGroupInventoryIsAuthoritative
    }

    private var workspaceGroupsForSelectedMachine: [MobileWorkspaceGroupPreview] {
        filteredWorkspaceGroups(
            workspaceGroups,
            macDeviceID: selectedMacDeviceID,
            instanceTag: selectedMacInstanceTag
        )
    }

    var resolvedWorkspaceGroupID: MobileWorkspaceGroupPreview.ID? {
        guard workspaceGroupInventoryIsAuthoritative,
              let validID = validWorkspaceGroupID(
            selectedWorkspaceGroupID,
            groups: workspaceGroups,
            macDeviceID: selectedMacDeviceID,
            instanceTag: selectedMacInstanceTag
        ) else { return nil }
        return validID
    }

    private var workspaceGroupSelectionKey: [MobileWorkspaceGroupPreview.ID] {
        workspaceGroupsForSelectedMachine.map(\.id)
    }

    var selectedMachine: MobilePairedMac? {
        machines.first {
            $0.id == selectedMacPairingID
        }
    }

    private var selectedMacPairingID: String {
        MobilePairedMac.pairingID(
            macDeviceID: selectedMacDeviceID,
            instanceTag: selectedMacInstanceTag
        )
    }

    var modelRefreshID: TaskComposerModelRefreshID {
        TaskComposerModelRefreshID(
            provider: selectedTemplate.flatMap {
                MobileTaskAgentProvider(command: $0.command)
            },
            macPairingID: selectedMacPairingID,
            connectionIdentity: store.taskModelConnectionIdentity(
                macDeviceID: selectedMacDeviceID,
                instanceTag: selectedMacInstanceTag
            )
        )
    }

    private var isModelLoading: Bool {
        displayedModels.isEmpty && modelRefreshOperationID != nil
    }

    private func updateModelLoadingIndicator(isLoading: Bool) async {
        guard isModelLoadingIndicatorVisible != isLoading else { return }
        // task(id:) cancels this debounce when the fetch changes state. Fast
        // responses never flash, while a visible pill gets a short exit dwell.
        do {
            try await modelLoadingIndicatorClock.sleep(for: .milliseconds(80))
        } catch {
            return
        }
        guard !Task.isCancelled else { return }
        withAnimation(accessibilityReduceMotion ? nil : .easeInOut(duration: 0.12)) {
            isModelLoadingIndicatorVisible = isLoading
        }
    }

    private func restartModelRefresh() {
        modelRefreshTask?.cancel()
        modelRefreshOperationID = nil
        guard let provider = modelRefreshID.provider,
              !selectedMacDeviceID.isEmpty else {
            displayedModels = []
            displayedDefaultModel = nil
            displayedModelError = nil
            reconcileSelectedEffort()
            modelRefreshTask = nil
            return
        }
        let macDeviceID = selectedMacDeviceID
        let instanceTag = selectedMacInstanceTag
        let refreshID = modelRefreshID
        let operationID = UUID()
        modelRefreshOperationID = operationID
        let cachedResult = store.discoveredTaskModelResult(
            provider: provider,
            macDeviceID: macDeviceID,
            instanceTag: instanceTag
        ) ?? MobileTaskModelListResult(models: [], source: .fallback)
        // Keep a usable cached catalog visible while the host and backend are
        // refreshed. An authoritative host result replaces it in place.
        displayedModels = cachedResult.models
        displayedDefaultModel = cachedResult.defaultModel
        displayedModelError = cachedResult.error
        reconcileSelectedEffort()
        modelRefreshTask = Task {
            await store.refreshTaskModels(
                provider: provider,
                macDeviceID: macDeviceID,
                instanceTag: instanceTag
            ) { result in
                guard !Task.isCancelled,
                      modelRefreshOperationID == operationID,
                      modelRefreshID == refreshID else { return }
                displayedModels = result.models
                displayedDefaultModel = result.defaultModel
                displayedModelError = result.error
                reconcileSelectedEffort()
            }
            guard !Task.isCancelled,
                  modelRefreshOperationID == operationID,
                  modelRefreshID == refreshID else { return }
            if let refreshedResult = store.discoveredTaskModelResult(
                provider: provider,
                macDeviceID: macDeviceID,
                instanceTag: instanceTag
            ) {
                displayedModels = refreshedResult.models
                displayedDefaultModel = refreshedResult.defaultModel
                displayedModelError = refreshedResult.error
                reconcileSelectedEffort()
            }
            modelRefreshOperationID = nil
            modelRefreshTask = nil
        }
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
        guard !submissionPhase.disablesRequestEditing,
              let template = templates.first(where: { $0.id == id }) else { return }
        withAnimation(accessibilityReduceMotion ? nil : .snappy(duration: 0.2)) {
            selectTemplate(template)
        }
    }

    private func presentTemplateEditor() {
        persistDraft()
        isEditorPresented = true
    }

    /// Leave-relevant state right now, compared against the session baseline.
    var currentSessionFingerprint: TaskComposerSessionFingerprint {
        TaskComposerSessionFingerprint(
            prompt: prompt,
            workspaceName: workspaceName,
            templateID: selectedTemplateID,
            macPairingID: MobilePairedMac.pairingID(
                macDeviceID: selectedMacDeviceID,
                instanceTag: selectedMacInstanceTag
            ),
            directory: directory,
            didEditDirectory: didEditDirectory,
            workspaceGroupID: selectedWorkspaceGroupID,
            attachmentIDs: isDraftAttachmentRestorePending
                ? Set(restoredDraftAttachments.map(\.id))
                : Set(attachments.map(\.id))
        )
    }

    /// Whether leaving now would abandon anything the user changed this
    /// session, including deliberate model and effort picks (automatic
    /// catalog reconciliation does not count).
    var hasUnsavedComposerChanges: Bool {
        currentSessionFingerprint != initialSessionFingerprint
            || hasUserPickedModelOrEffort
    }

    private func cancelComposer() {
        guard hasUnsavedComposerChanges else {
            // Nothing changed this session: a resumed draft stays exactly as
            // saved, and a fresh empty session leaves nothing behind.
            shouldPersistDraftOnDisappear = false
            dismiss()
            return
        }
        isLeaveConfirmationPresented = true
    }

    /// Confirmed "Save Draft" while leaving.
    func saveDraftAndDismiss() {
        persistDraft()
        shouldPersistDraftOnDisappear = false
        dismiss()
    }

    /// Confirmed "Delete Draft" while leaving: the previous cancel semantics.
    func deleteDraftAndDismiss() {
        store.recordAppEvent(
            .taskSubmitCancelled,
            correlationID: submissionIdentity.id.uuidString,
            failure: .cancelled
        )
        submitTask?.cancel()
        shouldPersistDraftOnDisappear = false
        store.deleteTaskComposerDrafts(
            ids: [draftID],
            ifSessionGeneration: sessionGeneration
        )
        dismiss()
    }

    /// The drafts toolbar affordance; hidden for hosts without a presenter.
    private var openDraftsAction: (() -> Void)? {
        guard onSwitchDraft != nil else { return nil }
        return { presentDraftsList() }
    }

    /// Opens the saved-drafts list; the sheet loads its rows on appear.
    private func presentDraftsList() {
        isDraftsListPresented = true
    }

    /// Saves the current content under this session's identity, then hands
    /// the presenter another draft to rebuild the composer from. A failed
    /// save keeps the session in place instead of silently discarding it.
    private func resumeDraft(_ id: UUID) {
        guard let onSwitchDraft else { return }
        guard persistDraftContent(base: draftSnapshot()) else { return }
        // The replaced view's onDisappear must not persist again: state
        // storage is already torn down by the identity switch, so that late
        // persist reads initial values and its empty snapshot would delete
        // the draft that was just saved.
        shouldPersistDraftOnDisappear = false
        onSwitchDraft(.resume(id))
    }

    /// Saves the current content as its own draft and starts a fresh one.
    /// A failed save keeps the session in place instead of discarding it.
    private func startNewDraft() {
        guard let onSwitchDraft else { return }
        guard persistDraftContent(base: draftSnapshot()) else { return }
        // See resumeDraft: block the torn-down view's late empty persist.
        shouldPersistDraftOnDisappear = false
        onSwitchDraft(.new)
    }

    private func deleteDrafts(_ ids: Set<UUID>) {
        store.deleteTaskComposerDrafts(
            ids: ids,
            ifSessionGeneration: sessionGeneration
        )
    }

    private func selectMachine(_ macDeviceID: String, _ instanceTag: String?) {
        guard !submissionPhase.disablesRequestEditing,
              machines.contains(where: {
                  $0.id == MobilePairedMac.pairingID(
                      macDeviceID: macDeviceID,
                      instanceTag: instanceTag
                  )
              }) else { return }
        store.recordAppEvent(
            .taskMachineSelected,
            correlationID: macDeviceID
        )
        store.recordAppEvent(
            .taskRouteSelected,
            correlationID: MobilePairedMac.pairingID(
                macDeviceID: macDeviceID,
                instanceTag: instanceTag
            )
        )
        updateSubmissionRequest(reconcileRecovery: true) {
            selectedMacDeviceID = macDeviceID
            selectedMacInstanceTag = instanceTag
            pendingRestoredWorkspaceGroupID = nil
            workspaceGroupSelectionRequiresResolution = false
            selectedWorkspaceGroupID = validWorkspaceGroupID(
                selectedWorkspaceGroupID,
                groups: workspaceGroups,
                macDeviceID: macDeviceID,
                instanceTag: instanceTag
            )
            syncSuggestedDirectory()
        }
    }

    private func selectWorkspaceGroup(_ groupID: MobileWorkspaceGroupPreview.ID?) {
        guard !submissionPhase.disablesRequestEditing,
              groupID == nil
                || workspaceGroupsForSelectedMachine.contains(where: { $0.id == groupID }) else {
            return
        }
        updateSubmissionRequest(reconcileRecovery: true) {
            pendingRestoredWorkspaceGroupID = nil
            workspaceGroupSelectionRequiresResolution = false
            selectedWorkspaceGroupID = groupID
        }
    }

    func startSubmission() {
        resolveCompletedOperationRecoveryAfterEditing()
        guard submitTask == nil,
              attachmentStagingTask == nil,
              blockingCompletedOperationRecovery == nil,
              submissionPhase.allowsSubmission,
              !workspaceGroupSelectionNeedsInventory,
              !workspaceGroupSelectionRequiresResolution else { return }
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
        guard persistDraftContent(base: snapshot.draft) else {
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
            persistDraftContent(base: snapshot.draft)
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
                persistDraftContent(base: draftSnapshot())
            } else {
                persistDraftContent(base: snapshot.draft)
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
            explicitlySelectedModel = nil
            selectedEffortID = nil
            syncSuggestedDirectory()
        }
        store.recordAppEvent(
            .taskTemplateCreated,
            correlationID: template.id.uuidString
        )
    }

    private func updateTemplate(_ template: MobileTaskTemplate) {
        guard !submissionPhase.disablesRequestEditing else { return }
        store.taskTemplateStore?.updateTemplate(template)
        store.recordAppEvent(
            .taskTemplateUpdated,
            correlationID: template.id.uuidString
        )
    }

    private func deleteTemplates(_ offsets: IndexSet) {
        guard !submissionPhase.disablesRequestEditing else { return }
        let ids = Set(offsets.map { templates[$0].id })
        store.taskTemplateStore?.deleteTemplates(ids: ids)
        store.recordAppEvent(
            .taskTemplateDeleted,
            count: ids.count
        )
    }

    private func refreshTemplates() {
        guard !submissionPhase.disablesRequestEditing else { return }
        updateSubmissionRequest(reconcileRecovery: true) {
            templates = store.taskTemplateStore?.listTemplates() ?? []
            if let selectedTemplateID, !templates.contains(where: { $0.id == selectedTemplateID }) {
                self.selectedTemplateID = templates.first?.id
            }
            selectedModelID = selectedModel?.id
            reconcileSelectedEffort()
            // Sync template edits unless the user typed the directory.
            syncSuggestedDirectory()
        }
        store.recordAppEvent(
            .taskTemplateListLoaded,
            count: templates.count
        )
    }

    private func validateMacSelection() {
        guard !submissionPhase.disablesRequestEditing else { return }
        guard selectedMachine == nil else { return }
        updateSubmissionRequest(reconcileRecovery: true) {
            selectedMacDeviceID = machines.first?.macDeviceID ?? ""
            selectedMacInstanceTag = machines.first?.instanceTag
            pendingRestoredWorkspaceGroupID = nil
            workspaceGroupSelectionRequiresResolution = false
            selectedWorkspaceGroupID = validWorkspaceGroupID(
                selectedWorkspaceGroupID,
                groups: workspaceGroups,
                macDeviceID: selectedMacDeviceID,
                instanceTag: selectedMacInstanceTag
            )
            syncSuggestedDirectory()
        }
    }

    private func validateWorkspaceGroupSelection() {
        // A live callback can arrive while the create is in flight. Preserve
        // the request exactly until editing is enabled again.
        guard !submissionPhase.disablesRequestEditing else { return }
        guard let selectedWorkspaceGroupID else {
            pendingRestoredWorkspaceGroupID = nil
            workspaceGroupSelectionRequiresResolution = false
            return
        }

        guard workspaceGroupInventoryIsAuthoritative else {
            pendingRestoredWorkspaceGroupID = selectedWorkspaceGroupID
            workspaceGroupSelectionRequiresResolution = false
            return
        }

        if validWorkspaceGroupID(
            selectedWorkspaceGroupID,
            groups: workspaceGroups,
            macDeviceID: selectedMacDeviceID,
            instanceTag: selectedMacInstanceTag
        ) != nil {
            pendingRestoredWorkspaceGroupID = nil
            workspaceGroupSelectionRequiresResolution = false
            return
        }

        // The authoritative inventory disproved the restored destination. Keep
        // it visible in the draft, block submission, and require an explicit
        // replacement or None selection instead of silently rerouting.
        pendingRestoredWorkspaceGroupID = selectedWorkspaceGroupID
        workspaceGroupSelectionRequiresResolution = true
    }

    private func persistDraft() {
        guard shouldPersistDraftOnDisappear else { return }
        if let activeSubmissionSnapshot {
            persistDraftContent(base: activeSubmissionSnapshot.draft)
            return
        }
        persistDraftContent(base: draftSnapshot())
    }

    /// Persists `base` under this session's identity with the session's
    /// attachments preserved into draft-owned files.
    @discardableResult
    func persistDraftContent(base: MobileTaskComposerDraft) -> Bool {
        var content = base
        content.attachments = persistedDraftAttachments()
        return store.persistTaskComposerDraft(
            content,
            draftID: draftID,
            ifSessionGeneration: sessionGeneration
        )
    }

    /// Copies every staged attachment into draft-owned storage and returns
    /// their preserved references. While the resume re-stage is still
    /// pending, the resumed references are reused verbatim so an early leave
    /// cannot drop them.
    private func persistedDraftAttachments() -> [MobileTaskComposerDraftAttachment] {
        if isDraftAttachmentRestorePending, attachments.isEmpty {
            return restoredDraftAttachments
        }
        guard let templateStore = store.taskTemplateStore else { return [] }
        var entries: [MobileTaskComposerDraftAttachment] = []
        for attachment in attachments {
            let displayNameExtension = (attachment.displayName as NSString).pathExtension
            let preferredExtension = displayNameExtension.isEmpty
                ? attachment.localStagedFileURL.pathExtension
                : displayNameExtension
            do {
                let relativePath = try templateStore.persistComposerAttachmentFile(
                    draftID: draftID,
                    attachmentID: attachment.id,
                    preferredExtension: preferredExtension,
                    from: attachment.localStagedFileURL
                )
                entries.append(attachment.draftAttachment(relativePath: relativePath))
            } catch {
                store.recordAppEvent(
                    .draftPersistenceFailed,
                    failure: DiagnosticFailureKind.classify(error)
                )
            }
        }
        return entries
    }

    /// Re-stages preserved draft attachments into fresh session-owned
    /// temporary copies, so session teardown never deletes draft-owned bytes.
    func restoreDraftAttachments() {
        guard !restoredDraftAttachments.isEmpty, attachments.isEmpty else {
            isDraftAttachmentRestorePending = false
            return
        }
        attachmentStagingTask?.cancel()
        attachmentStagingTask = Task { @MainActor in
            defer { attachmentStagingTask = nil }
            var restored: [TaskComposerAttachment] = []
            for entry in restoredDraftAttachments {
                guard !Task.isCancelled else { break }
                guard let sourceURL = store.taskTemplateStore?
                    .composerAttachmentFileURL(relativePath: entry.relativePath) else {
                    store.recordAppEvent(
                        .draftPersistenceFailed,
                        failure: .localStateUnavailable
                    )
                    continue
                }
                let fileExtension = (entry.relativePath as NSString).pathExtension
                let stagedURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(
                        "cmux-task-attachment-\(UUID().uuidString)"
                            + (fileExtension.isEmpty ? "" : ".\(fileExtension)")
                    )
                do {
                    try FileManager.default.copyItem(at: sourceURL, to: stagedURL)
                } catch {
                    store.recordAppEvent(
                        .draftPersistenceFailed,
                        failure: DiagnosticFailureKind.classify(error)
                    )
                    continue
                }
                restored.append(TaskComposerAttachment(
                    id: entry.id,
                    kind: TaskComposerAttachment.Kind(persistedValue: entry.kind),
                    displayName: entry.displayName,
                    localStagedFileURL: stagedURL,
                    byteCount: entry.byteCount,
                    thumbnailData: entry.thumbnailData
                ))
            }
            guard !Task.isCancelled else {
                for attachment in restored {
                    try? FileManager.default.removeItem(at: attachment.localStagedFileURL)
                }
                return
            }
            // Direct assignment: restoring saved state is not a user edit and
            // must not rotate a still-valid retry identity.
            attachments = restored
            isDraftAttachmentRestorePending = false
        }
    }

    private func validWorkspaceGroupID(
        _ candidate: MobileWorkspaceGroupPreview.ID?,
        groups: [MobileWorkspaceGroupPreview],
        macDeviceID: String,
        instanceTag: String?
    ) -> MobileWorkspaceGroupPreview.ID? {
        guard let candidate,
              filteredWorkspaceGroups(
                  groups,
                  macDeviceID: macDeviceID,
                  instanceTag: instanceTag
              ).contains(where: { $0.id == candidate }) else {
            return nil
        }
        return candidate
    }

    private func filteredWorkspaceGroups(
        _ groups: [MobileWorkspaceGroupPreview],
        macDeviceID: String,
        instanceTag: String?
    ) -> [MobileWorkspaceGroupPreview] {
        guard let macDeviceID = normalizedWorkspaceOwner(macDeviceID) else {
            return []
        }
        return groups.filter { group in
            guard let groupMacDeviceID = normalizedWorkspaceOwner(group.macDeviceID),
                  groupMacDeviceID == macDeviceID else {
                return false
            }
            return normalizedWorkspaceOwner(group.macInstanceTag) == normalizedWorkspaceOwner(instanceTag)
        }
    }

    private func normalizedWorkspaceOwner(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }
}
#endif
