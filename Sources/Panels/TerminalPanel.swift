import Foundation
import CmuxTerminalCore
import Combine
import AppKit
import Bonsplit
import CmuxRemoteSession
import CmuxTerminal
import CmuxWorkspaces

struct AgentHibernationPanelState {
    let agent: SessionRestorableAgentSnapshot
    let hibernatedAt: Date
    let lastActivityAt: Date

    var agentDisplayName: String {
        agent.agentDisplayName
    }
}

enum AgentHibernationResumePreparation: Equatable {
    case unavailable
    case resumed(queuedStartupInput: Bool)

    var didResume: Bool {
        if case .resumed = self { return true }
        return false
    }

    var queuedStartupInput: Bool {
        if case .resumed(let queuedStartupInput) = self { return queuedStartupInput }
        return false
    }
}

/// TerminalPanel wraps an existing TerminalSurface and conforms to the Panel protocol.
/// This allows TerminalSurface to be used within the bonsplit-based layout system.
@MainActor
final class TerminalPanel: Panel, ObservableObject {
    /// Bounds files retained while SwiftUI has not mounted the text-box view.
    /// Duplicate standardized URLs share one queue entry.
    static let maximumPendingTextBoxAttachmentCount = 64
    static let preparedTextBoxAttachmentReservedBytes = 32 * 1024 * 1024

    typealias TextBoxAttachmentPreparer = @Sendable (
        URL,
        TerminalImageTransferTarget
    ) async -> TextBoxPreparedFileAttachment?
    typealias TextBoxAttachmentDeadlineWaiter = @Sendable () async throws -> Void
    typealias TextBoxAttachmentRemoteUploader = (
        URL,
        TerminalImageTransferOperation,
        @escaping @Sendable (Result<[String], Error>) -> Void
    ) -> Void

    nonisolated static let defaultTextBoxAttachmentDeadlineWaiter: TextBoxAttachmentDeadlineWaiter = {
        try await ContinuousClock().sleep(for: .seconds(60))
    }

    private typealias PendingTextBoxAttachmentEnqueueResult =
        TerminalPanelPendingTextBoxAttachmentEnqueueResult
    private typealias PendingTextBoxAttachmentRequest =
        TerminalPanelPendingTextBoxAttachmentRequest
    private typealias PreparedTextBoxAttachmentPhase =
        TerminalPanelPreparedTextBoxAttachmentPhase
    private typealias PreparedTextBoxAttachmentRequest =
        TerminalPanelPreparedTextBoxAttachmentRequest

    private enum TextBoxInputFocusIntent: Equatable {
        case hidden
        case terminal
        case textBox
    }

    let id: UUID
    let stableSurfaceIdentity = PanelStableSurfaceIdentity()
    let panelType: PanelType = .terminal

    /// The underlying terminal surface
    let surface: TerminalSurface

    /// The workspace ID this panel belongs to
    private(set) var workspaceId: UUID

    var ownedSessionScrollbackReplayFileURL: URL? = nil
    /// The workspace-env key/value pairs this panel inherited from its workspace's
    /// `workspaceEnvironment` at creation. The same panel travels when a surface is
    /// moved between workspaces, so a respawn uses these to drop the (possibly
    /// previous) workspace's variables and re-apply the current workspace's. The
    /// value (not just the key) is tracked so an explicit per-surface override that
    /// happens to share a workspace key (e.g. a layout `env` AWS_PROFILE=staging in
    /// a workspace with AWS_PROFILE=prod) is preserved on respawn rather than being
    /// stripped and replaced by the workspace value (issue #5995).
    var seededWorkspaceEnvironment: [String: String] = [:]

    /// Published title from the terminal process
    @Published private(set) var title: String = "Terminal"

    /// Published directory from the terminal
    @Published private(set) var directory: String = ""

    @Published private(set) var tmuxLayoutReport: TmuxPaneLayoutReport?
    let shellActivity = TerminalPanelShellActivityModel()
    let textBoxState = TerminalPanelTextBoxState()
    @Published var isTextBoxActive: Bool = false
    @Published var textBoxContent: String = ""
    @Published var textBoxAttachments: [TextBoxAttachment] = []
    weak var textBoxInputView: TextBoxInputTextView?
    private weak var mountedTextBoxInputView: TextBoxInputTextView?
    private var shouldFocusTextBoxWhenAvailable = false
    private var shouldOpenTextBoxFilePickerWhenAvailable = false
    private var pendingTextBoxAttachmentRequests:
        [PendingTextBoxAttachmentRequest] = []
    private var preparedTextBoxAttachmentRequestOrder: [UUID] = []
    private var preparedTextBoxAttachmentRequests:
        [UUID: PreparedTextBoxAttachmentRequest] = [:]
    private var preparedTextBoxAttachmentMaintenanceTasks:
        [UUID: Task<Void, Never>] = [:]
    private var isMutatingPreparedTextBoxAttachmentPlaceholders = false
    private var shouldHideTextBoxOnNextEscape = false
    private var textBoxInputFocusIntent: TextBoxInputFocusIntent = .hidden
    private var preservedTextBoxAttributedContent: NSAttributedString?
    private var restoredTextBoxDraft: SessionTextBoxInputDraftSnapshot?
    private var isClosingPanel = false
    private var didDiscardTextBoxContentForClose = false
#if DEBUG
    private struct DebugTextBoxInlineFixture {
        let localURL: URL?
        let beforeText: String
        let afterText: String
    }

    private var pendingDebugTextBoxInlineFixture: DebugTextBoxInlineFixture?

    var debugHasPendingTextBoxFocusRequest: Bool {
        shouldFocusTextBoxWhenAvailable || shouldOpenTextBoxFilePickerWhenAvailable
    }

    var debugHasTextBoxHideEscapeArm: Bool {
        shouldHideTextBoxOnNextEscape
    }
#endif

    /// Search state for find functionality
    @Published var searchState: TerminalSurface.SearchState? {
        didSet {
            surface.searchState = searchState
        }
    }

    /// Bump this token to force SwiftUI to call `updateNSView` on `GhosttyTerminalView`,
    /// which re-attaches the hosted view after bonsplit close/reparent operations.
    ///
    /// Without this, certain pane-close sequences can leave terminal views detached
    /// (hostedView.window == nil) until the user switches workspaces.
    @Published var viewReattachToken: UInt64 = 0

    @Published private(set) var agentHibernationState: AgentHibernationPanelState?

    var onRequestWorkspacePaneFlash: ((WorkspaceAttentionFlashReason) -> Void)?
    var onRequestAgentHibernationResume: ((Bool) -> Bool)?

    private var cancellables = Set<AnyCancellable>()

    var displayTitle: String {
        title.isEmpty ? "Terminal" : title
    }

    var displayIcon: String? {
        "terminal.fill"
    }

    func updateShellActivityState(_ state: PanelShellActivityState) {
        if shellActivity.state != state {
            shellActivity.state = state
        }
        textBoxState.updateShellActivityState(state)
    }

    func recordTextBoxLaunchCommand(_ command: String) {
        guard let boundedContext = TextBoxAgentDetection.boundedLaunchCommandContext(from: command) else { return }
        textBoxState.recordLaunchCommand(boundedContext)
    }

    func clearTextBoxLaunchCommand() {
        textBoxState.clearLaunchCommand()
    }

    var isDirty: Bool {
        // Bonsplit's "dirty" indicator is a very small dot in the tab strip.
        //
        // For terminals, `ghostty_surface_needs_confirm_quit` is driven by shell integration
        // heuristics and can be transiently (or permanently) wrong, which results in a dot
        // showing on every new terminal. That reads as a notification/alert and is misleading.
        //
        // We still honor `needsConfirmClose()` when actually closing a panel; we just don't
        // surface it as a tab-level dirty indicator.
        false
    }

    var isAgentHibernated: Bool {
        agentHibernationState != nil
    }

    /// The hosted NSView for embedding in SwiftUI
    var hostedView: GhosttySurfaceScrollView {
        surface.hostedView
    }

    var requestedWorkingDirectory: String? {
        surface.requestedWorkingDirectory
    }

    init(workspaceId: UUID, surface: TerminalSurface) {
        self.id = surface.id
        self.workspaceId = workspaceId
        self.surface = surface
        // Subscribe to surface's search state changes
        surface.$searchState
            .sink { [weak self] state in
                if self?.searchState !== state {
                    self?.searchState = state
                }
            }
            .store(in: &cancellables)
    }

    /// Create a new terminal panel with a fresh surface
    convenience init(
        id: UUID = UUID(),
        workspaceId: UUID,
        context: ghostty_surface_context_e = GHOSTTY_SURFACE_CONTEXT_SPLIT,
        configTemplate: CmuxSurfaceConfigTemplate? = nil,
        workingDirectory: String? = nil,
        portOrdinal: Int = 0,
        initialCommand: String? = nil,
        tmuxStartCommand: String? = nil,
        initialInput: String? = nil,
        initialEnvironmentOverrides: [String: String] = [:],
        additionalEnvironment: [String: String] = [:],
        focusPlacement: TerminalSurfaceFocusPlacement = .workspace,
        runtimeSpawnPolicy: TerminalSurfaceRuntimeSpawnPolicy = .immediate
    ) {
        let surface = TerminalSurface(
            id: id,
            tabId: workspaceId,
            context: context,
            configTemplate: configTemplate,
            workingDirectory: workingDirectory,
            portOrdinal: portOrdinal,
            initialCommand: initialCommand,
            tmuxStartCommand: tmuxStartCommand,
            initialInput: initialInput,
            initialEnvironmentOverrides: initialEnvironmentOverrides,
            additionalEnvironment: additionalEnvironment,
            focusPlacement: focusPlacement, runtimeSpawnPolicy: runtimeSpawnPolicy,
            preparePaneHost: { Self.prepareNotificationScrollReplay(for: $0, environment: additionalEnvironment) }
        )
        self.init(workspaceId: workspaceId, surface: surface)
        if Self.startsAtOwnedPrompt(
            configTemplate: configTemplate,
            initialCommand: initialCommand,
            tmuxStartCommand: tmuxStartCommand,
            initialInput: initialInput
        ) {
            updateShellActivityState(.promptIdle)
        }
    }

    private static func startsAtOwnedPrompt(
        configTemplate: CmuxSurfaceConfigTemplate?,
        initialCommand: String?,
        tmuxStartCommand: String?,
        initialInput: String?
    ) -> Bool {
        isBlank(initialCommand) &&
            isBlank(tmuxStartCommand) &&
            isBlank(initialInput) &&
            isBlank(configTemplate?.command) &&
            isBlank(configTemplate?.initialInput)
    }

    private static func isBlank(_ value: String?) -> Bool {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
    }

    func updateTitle(_ newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && title != trimmed {
            title = trimmed
        }
    }

    func updateDirectory(_ newDirectory: String) {
        let trimmed = newDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && directory != trimmed {
            directory = trimmed
        }
    }

    func updateWorkspaceId(_ newWorkspaceId: UUID) {
        workspaceId = newWorkspaceId
        surface.updateWorkspaceId(newWorkspaceId)
    }

    func updateTmuxLayoutReport(_ report: TmuxPaneLayoutReport?) {
        guard tmuxLayoutReport != report else { return }
        tmuxLayoutReport = report
    }

    @discardableResult
    func preferTextBoxInputWhenActivated() -> TextBoxInputRequestResult {
        isTextBoxActive = true
        textBoxInputFocusIntent = .textBox
        shouldFocusTextBoxWhenAvailable = true
        shouldOpenTextBoxFilePickerWhenAvailable = false
        shouldHideTextBoxOnNextEscape = false
        let hasMountedTextBox = textBoxInputView?.window != nil
        if focusTextBoxIfNeeded() {
            return .focused
        }
        guard hasMountedTextBox else {
            return .queued
        }
        shouldFocusTextBoxWhenAvailable = false
        return .failed
    }

    func showTextBoxInputWhenAvailable() {
        isTextBoxActive = true
        textBoxInputFocusIntent = .terminal
        shouldFocusTextBoxWhenAvailable = false
        shouldOpenTextBoxFilePickerWhenAvailable = false
        shouldHideTextBoxOnNextEscape = false
    }

    func registerTextBoxInputView(_ view: TextBoxInputTextView) {
        textBoxInputView = view
        mountedTextBoxInputView = nil
        // Registration runs from NSViewRepresentable.makeNSView. Defer all
        // restored content and prepared-placeholder mutations until AppKit
        // confirms that this exact view entered a window.
        view.onPendingAttachmentUploadPlaceholdersChanged = { [weak self, weak view] ids in
            guard let self, let view else { return }
            preparedTextBoxAttachmentPlaceholderIDsDidChange(ids, in: view)
        }
        if preparedTextBoxAttachmentRequestOrder.isEmpty {
            // Drafts without live prepared markers are safe to restore
            // silently during construction and preserve the existing direct
            // registration contract.
            if let restoredTextBoxDraft {
                self.restoredTextBoxDraft = nil
                view.installSessionDraft(restoredTextBoxDraft, notifyingTextChange: false)
            } else if let preservedTextBoxAttributedContent {
                self.preservedTextBoxAttributedContent = nil
                view.installPreservedContent(
                    preservedTextBoxAttributedContent,
                    notifyingTextChange: false
                )
            }
        } else if let restoredTextBoxDraft {
            self.restoredTextBoxDraft = nil
            view.installSessionDraft(restoredTextBoxDraft, notifyingTextChange: false)
        } else if let preservedTextBoxAttributedContent {
            // Keep the marker-bearing original for the confirmed mount, but
            // seed ordinary text and attachments now so an aborted
            // construction still preserves and cleans them correctly.
            let constructionContent =
                TextBoxInputTextView.attributedContentForPreservation(
                    from: preservedTextBoxAttributedContent
                )
            view.installPreservedContent(
                constructionContent,
                notifyingTextChange: false
            )
        }
    }

    func textBoxInputViewDidMoveToWindow(_ view: TextBoxInputTextView) {
        guard textBoxInputView === view, view.window != nil else { return }
        mountedTextBoxInputView = view
        if let restoredTextBoxDraft {
            self.restoredTextBoxDraft = nil
            view.installSessionDraft(restoredTextBoxDraft)
        } else if let preservedTextBoxAttributedContent {
            self.preservedTextBoxAttributedContent = nil
            view.installPreservedContent(preservedTextBoxAttributedContent)
        }
        installPendingPreparedTextBoxAttachmentPlaceholders(in: view)
        focusTextBoxIfNeeded()
        if !flushPendingTextBoxAttachmentsIfPossible(in: view),
           !pendingTextBoxAttachmentRequests.isEmpty {
            NSSound.beep()
        }
        drainPreparedTextBoxAttachmentRequests()
#if DEBUG
        applyPendingDebugTextBoxInlineFixtureIfNeeded()
#endif
    }

    @discardableResult
    func toggleTextBoxInput() -> Bool {
        setTextBoxInputEnabled(!isTextBoxActive).accepted
    }

    @discardableResult
    func setTextBoxInputEnabled(_ enabled: Bool) -> TextBoxInputRequestResult {
        if enabled {
            return preferTextBoxInputWhenActivated()
        }
        guard isTextBoxActive else {
            return .hidden
        }
        hideTextBoxInput()
        return isTextBoxActive ? .failed : .hidden
    }

    @discardableResult
    func focusTextBoxInputOrTerminal() -> Bool {
        if isTextBoxActive,
           textBoxInputFocusIntent == .textBox {
            shouldHideTextBoxOnNextEscape = false
            let didFocusTerminal = focusTerminalSurface(respectForeignFirstResponder: false)
            if !didFocusTerminal {
                textBoxInputFocusIntent = .textBox
            }
            return didFocusTerminal
        }

        return focusTextBoxInput()
    }

    @discardableResult
    func attachFileToTextBoxInput() -> Bool {
        textBoxInputFocusIntent = .textBox
        isTextBoxActive = true
        shouldFocusTextBoxWhenAvailable = true
        shouldOpenTextBoxFilePickerWhenAvailable = true
        shouldHideTextBoxOnNextEscape = false
        let hasMountedTextBox = textBoxInputView?.window != nil
        let didFocusTextBox = focusTextBoxIfNeeded()
        return didFocusTextBox || !hasMountedTextBox
    }

    /// Attaches caller-supplied files without presenting an open panel. If the
    /// text box has not mounted yet, registration flushes the immutable URLs.
    @discardableResult
    func attachFilesToTextBoxInput(_ fileURLs: [URL]) -> TextBoxAttachmentRequestResult {
        let standardizedURLs = fileURLs
            .filter(\.isFileURL)
            .map(\.standardizedFileURL)
        guard !standardizedURLs.isEmpty else { return .invalidFiles }
        switch enqueuePendingTextBoxAttachments(standardizedURLs) {
        case .queueFull:
            return .queueFull
        case .coalesced:
            return .queued
        case .added:
            break
        }

        _ = preferTextBoxInputWhenActivated()
        if let textBoxInputView, textBoxInputView.window != nil {
            return flushPendingTextBoxAttachmentsIfPossible(in: textBoxInputView)
                ? .completed
                : .insertionFailed
        }
        return .queued
    }

    /// Starts a panel-owned attachment request. The panel keeps the task,
    /// deadline, placeholder, route snapshot, upload operation, and completion
    /// together so moves and view reattachment cannot retarget the result.
    @discardableResult
    func prepareAndAttachFileToTextBoxInput(
        _ fileURL: URL,
        budget: TextBoxAttachmentPreparationBudget = .shared,
        deadlineWaiter: @escaping TextBoxAttachmentDeadlineWaiter =
            TerminalPanel.defaultTextBoxAttachmentDeadlineWaiter,
        completion: @escaping @MainActor (Bool) -> Void
    ) -> TextBoxAttachmentRequestResult {
        enqueuePreparedTextBoxAttachment(
            fileURL,
            using: { fileURL, target in
                await TextBoxPreparedFileAttachment.prepareForTextBoxRequest(
                    fileURL: fileURL,
                    uploadTarget: target
                )
            },
            budget: budget,
            deadlineWaiter: deadlineWaiter,
            completion: completion
        )
    }

    #if DEBUG
    /// Dependency-injection seam for deterministic preparation and upload
    /// tests. Release builds expose only the killable helper-backed entrypoint.
    @discardableResult
    func prepareAndAttachFileToTextBoxInputForTesting(
        _ fileURL: URL,
        using preparer: @escaping TextBoxAttachmentPreparer,
        target targetOverride: TerminalImageTransferTarget? = nil,
        remoteUploader: TextBoxAttachmentRemoteUploader? = nil,
        budget: TextBoxAttachmentPreparationBudget = .shared,
        deadlineWaiter: @escaping TextBoxAttachmentDeadlineWaiter =
            TerminalPanel.defaultTextBoxAttachmentDeadlineWaiter,
        completion: @escaping @MainActor (Bool) -> Void
    ) -> TextBoxAttachmentRequestResult {
        enqueuePreparedTextBoxAttachment(
            fileURL,
            using: preparer,
            target: targetOverride,
            remoteUploader: remoteUploader,
            budget: budget,
            deadlineWaiter: deadlineWaiter,
            completion: completion
        )
    }
    #endif

    private func enqueuePreparedTextBoxAttachment(
        _ fileURL: URL,
        using preparer: @escaping TextBoxAttachmentPreparer,
        target targetOverride: TerminalImageTransferTarget? = nil,
        remoteUploader: TextBoxAttachmentRemoteUploader? = nil,
        budget: TextBoxAttachmentPreparationBudget,
        deadlineWaiter: @escaping TextBoxAttachmentDeadlineWaiter,
        completion: @escaping @MainActor (Bool) -> Void
    ) -> TextBoxAttachmentRequestResult {
        guard fileURL.isFileURL else { return .invalidFiles }
        let standardizedURL = fileURL.standardizedFileURL

        guard pendingTextBoxAttachmentCount < Self.maximumPendingTextBoxAttachmentCount else {
            return .queueFull
        }
        let workspaceRemoteController = surface.owningWorkspace()?
            .remotePTYSessionControllerForSocketCommand()
        let capturedTarget =
            targetOverride ?? surface.managedImageTransferTargetSnapshot()
        let resolvedTarget: TerminalImageTransferTarget?
        switch capturedTarget {
        case .remote(.workspaceRemote)
            where workspaceRemoteController == nil && remoteUploader == nil:
            // A remote-workspace marker without its captured coordinator is
            // not an immutable upload route. Do not fall back to a live
            // workspace lookup after preparation.
            resolvedTarget = nil
        default:
            resolvedTarget = capturedTarget
        }
        if let resolvedTarget,
           let duplicateID = preparedTextBoxAttachmentRequestOrder.first(where: {
               guard let request = preparedTextBoxAttachmentRequests[$0]
               else {
                   return false
               }
               return preparedTextBoxAttachmentRequest(
                   request,
                   matchesFileURL: standardizedURL,
                   target: resolvedTarget,
                   workspaceRemoteController: workspaceRemoteController,
                   remoteUploader: remoteUploader
               )
           }) {
            preparedTextBoxAttachmentRequests[duplicateID]?
                .completions.append(completion)
            return .queued
        }

        let requestID = UUID()
        let composerID = id
        preparedTextBoxAttachmentRequestOrder.append(requestID)
        preparedTextBoxAttachmentRequests[requestID] = PreparedTextBoxAttachmentRequest(
            id: requestID,
            fileURL: standardizedURL,
            workspaceRemoteController: workspaceRemoteController,
            remoteUploader: remoteUploader,
            budget: budget,
            resolvedTarget: resolvedTarget,
            phase: resolvedTarget == nil ? .failed(nil) : .preparing,
            preparationPermit: nil,
            preparationTask: nil,
            deadlineTask: nil,
            placeholderWasInserted: false,
            completions: [completion]
        )

        _ = preferTextBoxInputWhenActivated()
        insertPreparedTextBoxAttachmentPlaceholderIfPossible(requestID: requestID)

        guard let resolvedTarget else {
            drainPreparedTextBoxAttachmentRequests()
            return .queued
        }

        let preparationTask = Task { [weak self] in
            guard let permit = await budget.acquire(
                composerID: composerID,
                reservedBytes: Self.preparedTextBoxAttachmentReservedBytes
            ) else {
                self?.failPreparedTextBoxAttachmentRequest(requestID: requestID)
                self?.drainPreparedTextBoxAttachmentRequests()
                return
            }
            guard self?.recordPreparedTextBoxAttachmentPreparationPermit(
                permit,
                requestID: requestID
            ) == true else {
                await budget.release(permit)
                return
            }
            let preparedFile = await Self.prepareTextBoxAttachmentOffMainActor(
                fileURL: standardizedURL,
                target: resolvedTarget,
                using: preparer
            )
            guard let self else {
                await preparedFile?.disposeOwnedLocalFileIfNeededOffMainActor()
                await budget.release(permit)
                return
            }
            let disposition = preparedTextBoxAttachmentPreparationDidFinish(
                requestID: requestID,
                preparedFile: preparedFile,
                permit: permit
            )
            if !disposition.retainedPermit {
                if let preparedFileToDispose = disposition.preparedFileToDispose {
                    await preparedFileToDispose.disposeOwnedLocalFileIfNeededOffMainActor()
                }
                await budget.release(permit)
            }
        }
        let deadlineTask = Task { [weak self] in
            do {
                try await deadlineWaiter()
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.preparedTextBoxAttachmentDeadlineDidExpire(requestID: requestID)
        }
        preparedTextBoxAttachmentRequests[requestID]?.preparationTask = preparationTask
        preparedTextBoxAttachmentRequests[requestID]?.deadlineTask = deadlineTask
        return .queued
    }

    private func preparedTextBoxAttachmentRequest(
        _ request: PreparedTextBoxAttachmentRequest,
        matchesFileURL fileURL: URL,
        target: TerminalImageTransferTarget,
        workspaceRemoteController: RemoteSessionCoordinator?,
        remoteUploader: TextBoxAttachmentRemoteUploader?
    ) -> Bool {
        guard request.fileURL == fileURL,
              request.resolvedTarget == target,
              request.remoteUploader == nil,
              remoteUploader == nil else {
            return false
        }
        if case .remote(.workspaceRemote) = target {
            return request.workspaceRemoteController
                === workspaceRemoteController
        }
        return true
    }

    private func recordPreparedTextBoxAttachmentPreparationPermit(
        _ permit: TextBoxAttachmentPreparationBudget.Permit,
        requestID: UUID
    ) -> Bool {
        guard var request = preparedTextBoxAttachmentRequests[requestID],
              case .preparing = request.phase,
              request.resolvedTarget != nil,
              request.preparationPermit == nil else {
            return false
        }
        request.preparationPermit = permit
        preparedTextBoxAttachmentRequests[requestID] = request
        return true
    }

    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated private static func prepareTextBoxAttachmentOffMainActor(
        fileURL: URL,
        target: TerminalImageTransferTarget,
        using preparer: @escaping TextBoxAttachmentPreparer
    ) async -> TextBoxPreparedFileAttachment? {
        await preparer(fileURL, target)
    }

    private func preparedTextBoxAttachmentPreparationDidFinish(
        requestID: UUID,
        preparedFile: TextBoxPreparedFileAttachment?,
        permit: TextBoxAttachmentPreparationBudget.Permit
    ) -> (
        retainedPermit: Bool,
        preparedFileToDispose: TextBoxPreparedFileAttachment?
    ) {
        guard var request = preparedTextBoxAttachmentRequests[requestID],
              case .preparing = request.phase,
              let resolvedTarget = request.resolvedTarget,
              request.preparationPermit == permit else {
            return (false, preparedFile)
        }

        let retainsPreparedBytes = preparedFile != nil
        request.preparationPermit = retainsPreparedBytes ? permit : nil
        switch preparedFile {
        case .some(let preparedFile):
            request.phase = .prepared(preparedFile, resolvedTarget)
        case .none:
            request.phase = .failed(nil)
        }
        preparedTextBoxAttachmentRequests[requestID] = request
        if case .prepared = request.phase {
            _ = preferTextBoxInputWhenActivated()
            insertPreparedTextBoxAttachmentPlaceholderIfPossible(requestID: requestID)
        }
        drainPreparedTextBoxAttachmentRequests()
        return (retainsPreparedBytes, nil)
    }

    private func preparedTextBoxAttachmentDeadlineDidExpire(requestID: UUID) {
        failPreparedTextBoxAttachmentRequest(requestID: requestID)
        drainPreparedTextBoxAttachmentRequests()
    }

    private func failPreparedTextBoxAttachmentRequest(requestID: UUID) {
        guard var request = preparedTextBoxAttachmentRequests[requestID] else { return }
        request.preparationTask?.cancel()
        request.deadlineTask?.cancel()
        switch request.phase {
        case .preparing:
            // The local preparation task owns this permit until its worker
            // actually returns. Cancellation and deadline expiry only finish
            // the ordered UI request.
            request.preparationPermit = nil
            request.phase = .failed(nil)
        case .prepared(let preparedFile, _),
             .uploaded(let preparedFile, _):
            request.phase = .failed(preparedFile)
        case .uploading(let preparedFile, let operation):
            _ = operation.cancel()
            surface.hostedView.endImageTransferIndicator(for: operation)
            request.phase = .failed(preparedFile)
        case .failed:
            break
        }
        preparedTextBoxAttachmentRequests[requestID] = request
    }

    private func insertPreparedTextBoxAttachmentPlaceholderIfPossible(requestID: UUID) {
        guard var request = preparedTextBoxAttachmentRequests[requestID],
              !request.placeholderWasInserted,
              let textBoxInputView,
              mountedTextBoxInputView === textBoxInputView,
              textBoxInputView.window != nil else {
            return
        }
        mutatePreparedTextBoxAttachmentPlaceholders {
            textBoxInputView.insertPendingAttachmentUploadPlaceholder(id: requestID)
        }
        request.placeholderWasInserted =
            textBoxInputView.pendingAttachmentUploadPlaceholderIDs().contains(requestID)
        preparedTextBoxAttachmentRequests[requestID] = request
    }

    private func installPendingPreparedTextBoxAttachmentPlaceholders(
        in textBoxInputView: TextBoxInputTextView
    ) {
        guard self.textBoxInputView === textBoxInputView,
              mountedTextBoxInputView === textBoxInputView,
              textBoxInputView.window != nil else {
            return
        }
        for requestID in preparedTextBoxAttachmentRequestOrder {
            insertPreparedTextBoxAttachmentPlaceholderIfPossible(requestID: requestID)
        }
    }

    private func mutatePreparedTextBoxAttachmentPlaceholders(
        _ mutation: () -> Void
    ) {
        let wasMutating = isMutatingPreparedTextBoxAttachmentPlaceholders
        isMutatingPreparedTextBoxAttachmentPlaceholders = true
        mutation()
        isMutatingPreparedTextBoxAttachmentPlaceholders = wasMutating
    }

    private func preparedTextBoxAttachmentPlaceholderIDsDidChange(
        _ reportedVisibleIDs: Set<UUID>,
        in textBoxInputView: TextBoxInputTextView
    ) {
        guard self.textBoxInputView === textBoxInputView,
              !isMutatingPreparedTextBoxAttachmentPlaceholders else {
            return
        }
        let liveRequestIDs = Set(preparedTextBoxAttachmentRequestOrder.filter {
            preparedTextBoxAttachmentRequests[$0]?.placeholderWasInserted == true
        })
        guard !liveRequestIDs.isEmpty || !reportedVisibleIDs.isEmpty else {
            return
        }
        var visibleIDs = Set<UUID>()
        mutatePreparedTextBoxAttachmentPlaceholders {
            visibleIDs = textBoxInputView.reconcilePendingAttachmentUploadPlaceholders(
                keeping: liveRequestIDs
            )
        }
        let deletedRequestIDs = preparedTextBoxAttachmentRequestOrder.filter { requestID in
            preparedTextBoxAttachmentRequests[requestID]?.placeholderWasInserted == true
                && !visibleIDs.contains(requestID)
        }
        guard !deletedRequestIDs.isEmpty else { return }
        for requestID in deletedRequestIDs {
            failPreparedTextBoxAttachmentRequest(requestID: requestID)
        }
        drainPreparedTextBoxAttachmentRequests()
    }

    private func drainPreparedTextBoxAttachmentRequests() {
        guard !isClosingPanel else { return }
        while let requestID = preparedTextBoxAttachmentRequestOrder.first,
              let request = preparedTextBoxAttachmentRequests[requestID] {
            switch request.phase {
            case .preparing, .uploading:
                return
            case .failed:
                finishPreparedTextBoxAttachmentRequest(
                    requestID: requestID,
                    didAttach: false,
                    removePlaceholder: true
                )
            case .prepared(let preparedFile, let target):
                guard let textBoxInputView,
                      mountedTextBoxInputView === textBoxInputView,
                      textBoxInputView.window != nil else {
                    return
                }
                switch target {
                case .local:
                    guard commitPreparedTextBoxAttachment(
                        requestID: requestID,
                        preparedFile: preparedFile,
                        submissionPath: preparedFile.fileURL.path
                    ) else {
                        return
                    }
                case .remote(let remoteTarget):
                    startPreparedTextBoxAttachmentUpload(
                        requestID: requestID,
                        preparedFile: preparedFile,
                        remoteTarget: remoteTarget
                    )
                    return
                }
            case .uploaded(let preparedFile, let remotePath):
                guard let textBoxInputView,
                      mountedTextBoxInputView === textBoxInputView,
                      textBoxInputView.window != nil else {
                    return
                }
                guard commitPreparedTextBoxAttachment(
                    requestID: requestID,
                    preparedFile: preparedFile,
                    submissionPath: remotePath
                ) else {
                    return
                }
            }
        }
    }

    private func commitPreparedTextBoxAttachment(
        requestID: UUID,
        preparedFile: TextBoxPreparedFileAttachment,
        submissionPath: String
    ) -> Bool {
        guard let request = preparedTextBoxAttachmentRequests[requestID],
              request.placeholderWasInserted,
              let textBoxInputView,
              mountedTextBoxInputView === textBoxInputView,
              textBoxInputView.window != nil else {
            return false
        }
        let attachment = TextBoxAttachment(
            preparedFile: preparedFile,
            submissionText: TextBoxAttachment.submissionText(forPath: submissionPath),
            submissionPath: submissionPath
        )
        var didReplace = false
        mutatePreparedTextBoxAttachmentPlaceholders {
            didReplace = textBoxInputView.replacePendingAttachmentUploadPlaceholder(
                id: requestID,
                with: [attachment]
            )
        }
        finishPreparedTextBoxAttachmentRequest(
            requestID: requestID,
            didAttach: didReplace,
            removePlaceholder: !didReplace
        )
        return true
    }

    private func startPreparedTextBoxAttachmentUpload(
        requestID: UUID,
        preparedFile: TextBoxPreparedFileAttachment,
        remoteTarget: TerminalRemoteUploadTarget
    ) {
        guard var request = preparedTextBoxAttachmentRequests[requestID] else {
            schedulePreparedTextBoxAttachmentMaintenance(
                preparedFileToDispose: preparedFile
            )
            return
        }
        let operation = TerminalImageTransferOperation()
        request.phase = .uploading(preparedFile, operation)
        preparedTextBoxAttachmentRequests[requestID] = request
        surface.hostedView.beginImageTransferIndicator(
            for: operation,
            onCancel: { [weak self] in
                MainActor.assumeIsolated {
                    self?.failPreparedTextBoxAttachmentRequest(requestID: requestID)
                    self?.drainPreparedTextBoxAttachmentRequests()
                }
            }
        )

        let finish: @Sendable (Result<[String], Error>) -> Void = { [weak self] result in
            Task { @MainActor in
                guard let self else {
                    await preparedFile.disposeOwnedLocalFileIfNeededOffMainActor()
                    return
                }
                self.preparedTextBoxAttachmentUploadDidFinish(
                    requestID: requestID,
                    preparedFile: preparedFile,
                    operation: operation,
                    result: result
                )
            }
        }

        if let remoteUploader = request.remoteUploader {
            remoteUploader(preparedFile.fileURL, operation, finish)
            return
        }

        switch remoteTarget {
        case .workspaceRemote:
            guard let controller = request.workspaceRemoteController else {
                surface.hostedView.endImageTransferIndicator(for: operation)
                _ = operation.finish()
                request.phase = .failed(preparedFile)
                preparedTextBoxAttachmentRequests[requestID] = request
                drainPreparedTextBoxAttachmentRequests()
                return
            }
            controller.uploadDroppedFiles(
                [preparedFile.fileURL],
                operation: operation,
                completion: finish
            )
        case .detectedSSH(let session):
            session.uploadDroppedFiles(
                [preparedFile.fileURL],
                operation: operation,
                completion: finish
            )
        }
    }

    private func preparedTextBoxAttachmentUploadDidFinish(
        requestID: UUID,
        preparedFile: TextBoxPreparedFileAttachment,
        operation: TerminalImageTransferOperation,
        result: Result<[String], Error>
    ) {
        surface.hostedView.endImageTransferIndicator(for: operation)
        guard operation.finish() else {
            if preparedTextBoxAttachmentRequests[requestID] == nil {
                schedulePreparedTextBoxAttachmentMaintenance(
                    preparedFileToDispose: preparedFile
                )
            }
            return
        }
        guard var request = preparedTextBoxAttachmentRequests[requestID],
              case .uploading(_, let currentOperation) = request.phase,
              currentOperation === operation else {
            schedulePreparedTextBoxAttachmentMaintenance(
                preparedFileToDispose: preparedFile
            )
            return
        }

        switch result {
        case .success(let remotePaths):
            if let remotePath = remotePaths.first,
               !remotePath.isEmpty {
                request.phase = .uploaded(preparedFile, remotePath: remotePath)
            } else {
                request.phase = .failed(preparedFile)
            }
        case .failure:
            request.phase = .failed(preparedFile)
        }
        preparedTextBoxAttachmentRequests[requestID] = request
        drainPreparedTextBoxAttachmentRequests()
    }

    private func finishPreparedTextBoxAttachmentRequest(
        requestID: UUID,
        didAttach: Bool,
        removePlaceholder: Bool
    ) {
        guard let request = preparedTextBoxAttachmentRequests.removeValue(
            forKey: requestID
        ) else {
            return
        }
        preparedTextBoxAttachmentRequestOrder.removeAll { $0 == requestID }
        request.preparationTask?.cancel()
        request.deadlineTask?.cancel()

        var preparedFileToDispose: TextBoxPreparedFileAttachment?
        let permitToRelease: TextBoxAttachmentPreparationBudget.Permit?
        if case .preparing = request.phase {
            // The task may be inside cancellation-ignoring synchronous work.
            // Its local permit remains authoritative until that work returns.
            permitToRelease = nil
        } else {
            permitToRelease = request.preparationPermit
        }
        if !didAttach {
            switch request.phase {
            case .preparing:
                break
            case .prepared(let preparedFile, _),
                 .uploaded(let preparedFile, _),
                 .failed(.some(let preparedFile)):
                preparedFileToDispose = preparedFile
            case .uploading(let preparedFile, let operation):
                _ = operation.cancel()
                surface.hostedView.endImageTransferIndicator(for: operation)
                preparedFileToDispose = preparedFile
            case .failed(.none):
                break
            }
        }
        schedulePreparedTextBoxAttachmentMaintenance(
            preparedFileToDispose: preparedFileToDispose,
            budget: request.budget,
            permit: permitToRelease
        )

        if removePlaceholder {
            removePreparedTextBoxAttachmentPlaceholder(requestID: requestID)
        }
        for completion in request.completions {
            completion(didAttach)
        }
    }

    private func schedulePreparedTextBoxAttachmentMaintenance(
        preparedFileToDispose: TextBoxPreparedFileAttachment? = nil,
        budget: TextBoxAttachmentPreparationBudget? = nil,
        permit: TextBoxAttachmentPreparationBudget.Permit? = nil
    ) {
        guard preparedFileToDispose != nil || (budget != nil && permit != nil) else {
            return
        }
        let maintenanceID = UUID()
        let task = Task { [weak self] in
            if let preparedFileToDispose {
                await preparedFileToDispose.disposeOwnedLocalFileIfNeededOffMainActor()
            }
            if let budget, let permit {
                await budget.release(permit)
            }
            self?.preparedTextBoxAttachmentMaintenanceTasks.removeValue(
                forKey: maintenanceID
            )
        }
        preparedTextBoxAttachmentMaintenanceTasks[maintenanceID] = task
    }

    private func removePreparedTextBoxAttachmentPlaceholder(requestID: UUID) {
        if let textBoxInputView,
           mountedTextBoxInputView === textBoxInputView {
            mutatePreparedTextBoxAttachmentPlaceholders {
                _ = textBoxInputView.removePendingAttachmentUploadPlaceholder(
                    id: requestID
                )
            }
        }
        if let preservedTextBoxAttributedContent {
            self.preservedTextBoxAttributedContent =
                TextBoxInputTextView.attributedContentForPreservation(
                    from: preservedTextBoxAttributedContent,
                    preservingPendingAttachmentUploadPlaceholderIDs:
                        Set(preparedTextBoxAttachmentRequestOrder)
                )
        }
    }

    private func cancelAllPreparedTextBoxAttachmentRequests() {
        let requestIDs = preparedTextBoxAttachmentRequestOrder
        for requestID in requestIDs {
            finishPreparedTextBoxAttachmentRequest(
                requestID: requestID,
                didAttach: false,
                removePlaceholder: true
            )
        }
        preparedTextBoxAttachmentRequestOrder.removeAll(keepingCapacity: false)
        preparedTextBoxAttachmentRequests.removeAll(keepingCapacity: false)
    }

    private func cancelAllPendingTextBoxAttachmentRequests() {
        let completions = pendingTextBoxAttachmentRequests.flatMap(\.completions)
        pendingTextBoxAttachmentRequests.removeAll(keepingCapacity: false)
        for completion in completions {
            completion(false)
        }
    }

    private var pendingTextBoxAttachmentCount: Int {
        pendingTextBoxAttachmentRequests.reduce(into: 0) {
            $0 += 1 + $1.completions.count
        }
            + preparedTextBoxAttachmentRequests.values.reduce(into: 0) {
                $0 += $1.completions.count
            }
    }

    /// Adds a request atomically so a request that would cross the bound cannot
    /// leave a partially queued set of files behind.
    private func enqueuePendingTextBoxAttachments(
        _ standardizedURLs: [URL]
    ) -> PendingTextBoxAttachmentEnqueueResult {
        var seenURLs = Set(pendingTextBoxAttachmentRequests.map(\.fileURL))
        var newURLs: [URL] = []
        newURLs.reserveCapacity(min(
            standardizedURLs.count,
            max(0, Self.maximumPendingTextBoxAttachmentCount - pendingTextBoxAttachmentCount)
        ))

        for url in standardizedURLs where seenURLs.insert(url).inserted {
            guard pendingTextBoxAttachmentCount + newURLs.count
                    < Self.maximumPendingTextBoxAttachmentCount else {
                return .queueFull
            }
            newURLs.append(url)
        }

        guard !newURLs.isEmpty else { return .coalesced }
        pendingTextBoxAttachmentRequests.append(contentsOf: newURLs.map {
            PendingTextBoxAttachmentRequest(fileURL: $0, completions: [])
        })
        return .added
    }

    @discardableResult
    private func flushPendingTextBoxAttachmentsIfPossible(
        in view: TextBoxInputTextView
    ) -> Bool {
        guard textBoxInputView === view,
              view.window != nil,
              !pendingTextBoxAttachmentRequests.isEmpty else {
            return false
        }
        let pendingRequests = pendingTextBoxAttachmentRequests
        let attemptedURLs = Set(pendingRequests.map(\.fileURL))
        let didInsert = view.onInsertFileURLs(
            pendingRequests.map(\.fileURL),
            view
        )
        let completions = pendingTextBoxAttachmentRequests
            .filter { attemptedURLs.contains($0.fileURL) }
            .flatMap(\.completions)
        if didInsert {
            pendingTextBoxAttachmentRequests.removeAll {
                attemptedURLs.contains($0.fileURL)
            }
        } else {
            for index in pendingTextBoxAttachmentRequests.indices
            where attemptedURLs.contains(pendingTextBoxAttachmentRequests[index].fileURL) {
                pendingTextBoxAttachmentRequests[index]
                    .completions.removeAll(keepingCapacity: false)
            }
        }
        for completion in completions {
            completion(didInsert)
        }
        return didInsert
    }

    func textBoxDidBecomeFocused() {
        shouldHideTextBoxOnNextEscape = false
        isTextBoxActive = true
        textBoxInputFocusIntent = .textBox
        surface.setFocus(false)
        hostedView.setActive(false)
    }

    func terminalDidBecomeFocused() {
        guard isTextBoxActive else { return }
        shouldFocusTextBoxWhenAvailable = false
        shouldOpenTextBoxFilePickerWhenAvailable = false
        textBoxInputFocusIntent = .terminal
    }

    func handleTextBoxEscape() {
        let hadTextBoxView = textBoxInputView != nil
        let didFocusTerminal = focusTerminalSurface(
            respectForeignFirstResponder: false,
            clearTextBoxHideArm: false
        )
        shouldHideTextBoxOnNextEscape = isTextBoxActive && (hadTextBoxView || didFocusTerminal)
    }

    @discardableResult
    func consumeTextBoxHideEscapeIfArmed(in window: NSWindow?) -> Bool {
        guard isTextBoxActive,
              shouldHideTextBoxOnNextEscape else {
            return false
        }
        guard textBoxOrSurfaceOwnsEscapeContext(in: window) else {
            shouldHideTextBoxOnNextEscape = false
            return false
        }
        hideTextBoxInput()
        return true
    }

    func clearTextBoxHideEscapeArm() {
        shouldHideTextBoxOnNextEscape = false
    }

    private func hideTextBoxInput() {
        shouldHideTextBoxOnNextEscape = false
        shouldFocusTextBoxWhenAvailable = false
        shouldOpenTextBoxFilePickerWhenAvailable = false
        textBoxInputFocusIntent = .hidden
        preserveTextBoxContentFromView()
        isTextBoxActive = false
        mountedTextBoxInputView = nil
        textBoxInputView = nil
        focusTerminalSurface(respectForeignFirstResponder: false)
    }

    private func preserveTextBoxContentFromView() {
        guard let textBoxInputView else { return }
        preserveTextBoxContentForUnmount(from: textBoxInputView)
    }

    func preserveTextBoxContentForUnmount(from textBoxInputView: TextBoxInputTextView) {
        // Dismantle can run while AttributeGraph is destroying this subtree. Cache only
        // non-published draft state here; normal editing keeps the published bindings current.
        if isClosingPanel {
            assert(
                didDiscardTextBoxContentForClose,
                "close() must discard TextBox content before SwiftUI dismantles the TextBox view"
            )
            recordTextBoxViewUnmounted(textBoxInputView)
            return
        }
        if mountedTextBoxInputView !== textBoxInputView,
           preservedTextBoxAttributedContent != nil {
            // Construction was dismantled before the marker-bearing content
            // could be installed. Retain the original anchor-bearing value.
            recordTextBoxViewUnmounted(textBoxInputView)
            return
        }
        let preservedContent = textBoxInputView.attributedContentForPreservation(
            preservingPendingAttachmentUploadPlaceholderIDs:
                Set(preparedTextBoxAttachmentRequestOrder)
        )
        textBoxInputView.invalidatePendingAttachmentUploads()
        preservedTextBoxAttributedContent = NSAttributedString(
            attributedString: preservedContent
        )
        recordTextBoxViewUnmounted(textBoxInputView)
    }

    private func recordTextBoxViewUnmounted(_ textBoxInputView: TextBoxInputTextView) {
        guard self.textBoxInputView === textBoxInputView else { return }
        textBoxInputView.onPendingAttachmentUploadPlaceholdersChanged = { _ in }
        mountedTextBoxInputView = nil
        self.textBoxInputView = nil
    }

    private func discardTextBoxContentForClose(from textBoxInputView: TextBoxInputTextView? = nil) {
        didDiscardTextBoxContentForClose = true
        cancelAllPendingTextBoxAttachmentRequests()
        cancelAllPreparedTextBoxAttachmentRequests()
        let currentTextView = textBoxInputView ?? self.textBoxInputView
        let attachmentsToCleanup = currentTextView?.inlineAttachments() ?? textBoxAttachments
        if let currentTextView {
            currentTextView.clearContent(cleanupAttachmentFiles: true)
            currentTextView.discardUndoHistoryAndCleanupPendingAttachmentFiles()
        } else if !attachmentsToCleanup.isEmpty {
            let cleanupTextView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
            cleanupTextView.cleanupDisposableAttachmentFiles(
                attachmentsToCleanup,
                preservingActiveInlineAttachments: false
            )
        }
        restoredTextBoxDraft = nil
        preservedTextBoxAttributedContent = nil
        textBoxContent = ""
        textBoxAttachments = []
        isTextBoxActive = false
        textBoxInputFocusIntent = .hidden
        shouldFocusTextBoxWhenAvailable = false
        shouldOpenTextBoxFilePickerWhenAvailable = false
        shouldHideTextBoxOnNextEscape = false
        if self.textBoxInputView === currentTextView {
            self.textBoxInputView = nil
        }
    }

    func sessionTextBoxDraftSnapshot() -> SessionTextBoxInputDraftSnapshot? {
        if let textBoxInputView {
            return textBoxInputView.sessionDraftSnapshot(isActive: isTextBoxActive)
        }

        if let restoredTextBoxDraft {
            return restoredTextBoxDraft
        }

        if let preservedTextBoxAttributedContent {
            return TextBoxInputTextView.sessionDraftSnapshot(
                from: TextBoxInputTextView.attributedContentForPreservation(
                    from: preservedTextBoxAttributedContent
                ),
                isActive: isTextBoxActive
            )
        }

        return TextBoxInputTextView.sessionDraftSnapshot(
            text: textBoxContent,
            attachments: textBoxAttachments,
            isActive: isTextBoxActive
        )
    }

    func restoreSessionTextBoxDraft(_ draft: SessionTextBoxInputDraftSnapshot?) {
        guard let draft,
              !draft.parts.isEmpty else {
            restoredTextBoxDraft = nil
            preservedTextBoxAttributedContent = nil
            textBoxContent = ""
            textBoxAttachments = []
            isTextBoxActive = false
            textBoxInputFocusIntent = .hidden
            shouldFocusTextBoxWhenAvailable = false
            shouldOpenTextBoxFilePickerWhenAvailable = false
            shouldHideTextBoxOnNextEscape = false
            return
        }

        restoredTextBoxDraft = draft
        preservedTextBoxAttributedContent = nil
        textBoxContent = TextBoxInputTextView.plainText(from: draft)
        textBoxAttachments = TextBoxInputTextView.attachments(from: draft)
        isTextBoxActive = draft.isActive
        textBoxInputFocusIntent = draft.isActive ? .textBox : .hidden
        shouldFocusTextBoxWhenAvailable = false
        shouldOpenTextBoxFilePickerWhenAvailable = false
        shouldHideTextBoxOnNextEscape = false
    }

    @discardableResult
    private func focusTextBoxIfNeeded() -> Bool {
        guard shouldFocusTextBoxWhenAvailable,
              isTextBoxActive,
              let textBoxInputView,
              let window = textBoxInputView.window else { return false }
        guard window.makeFirstResponder(textBoxInputView) else { return false }
        shouldFocusTextBoxWhenAvailable = false
        textBoxInputFocusIntent = .textBox
        surface.setFocus(false)
        hostedView.setActive(false)
        if shouldOpenTextBoxFilePickerWhenAvailable {
            shouldOpenTextBoxFilePickerWhenAvailable = false
            textBoxInputView.openFilePicker()
        }
        return true
    }

    @discardableResult
    private func focusTextBoxInput() -> Bool {
        textBoxInputFocusIntent = .textBox
        isTextBoxActive = true
        shouldFocusTextBoxWhenAvailable = true
        shouldHideTextBoxOnNextEscape = false
        let hasMountedTextBox = textBoxInputView?.window != nil
        let didFocusTextBox = focusTextBoxIfNeeded()
        return didFocusTextBox || !hasMountedTextBox
    }

#if DEBUG
    @discardableResult
    func installDebugTextBoxInlineFixture(
        localURL: URL?,
        beforeText: String,
        afterText: String
    ) -> Bool {
        textBoxInputFocusIntent = .textBox
        isTextBoxActive = true
        shouldFocusTextBoxWhenAvailable = true

        let fixture = DebugTextBoxInlineFixture(
            localURL: localURL?.standardizedFileURL,
            beforeText: beforeText,
            afterText: afterText
        )

        pendingDebugTextBoxInlineFixture = fixture
        applyPendingDebugTextBoxInlineFixtureIfNeeded()
        return true
    }

    private func applyPendingDebugTextBoxInlineFixtureIfNeeded() {
        guard let fixture = pendingDebugTextBoxInlineFixture,
              let textBoxInputView,
              let textBoxWindow = textBoxInputView.window,
              textBoxWindow === hostedView.window else { return }
        pendingDebugTextBoxInlineFixture = nil
        applyDebugTextBoxInlineFixture(fixture, to: textBoxInputView)
    }

    private func applyDebugTextBoxInlineFixture(
        _ fixture: DebugTextBoxInlineFixture,
        to textBoxInputView: TextBoxInputTextView
    ) {
        textBoxInputView.window?.makeFirstResponder(textBoxInputView)
        let attachment = fixture.localURL.map {
                TextBoxAttachment(
                    localURL: $0,
                    submissionText: TextBoxAttachment.submissionText(forLocalFileURL: $0)
                )
        }
        textBoxContent = fixture.beforeText + fixture.afterText
        textBoxAttachments = attachment.map { [$0] } ?? []
        textBoxInputView.installInlineControlFixture(
            attachment,
            beforeText: fixture.beforeText,
            afterText: fixture.afterText
        )
        textBoxContent = textBoxInputView.plainText()
        textBoxAttachments = textBoxInputView.inlineAttachments()
    }
#endif

    func focus() {
        focus(focusTransactionId: nil)
    }

    func focus(focusTransactionId: UUID?) {
        if isAgentHibernated {
            _ = requestAgentHibernationResume(focus: true)
            return
        }
        focusTerminalSurface(
            respectForeignFirstResponder: true,
            focusTransactionId: focusTransactionId
        )
    }

    @discardableResult
    private func focusTerminalSurface(
        respectForeignFirstResponder: Bool,
        clearTextBoxHideArm: Bool = true,
        focusTransactionId: UUID? = nil
    ) -> Bool {
        if clearTextBoxHideArm {
            shouldHideTextBoxOnNextEscape = false
        }
        if isTextBoxActive,
           respectForeignFirstResponder,
           textBoxInputFocusIntent == .textBox {
            hostedView.yieldTerminalSurfaceFocusForForeignResponder(reason: "textbox.preserveFocusIntent")
            hostedView.setActive(false)
            return true
        }
        if isTextBoxActive {
            textBoxInputFocusIntent = .terminal
            shouldFocusTextBoxWhenAvailable = false
            shouldOpenTextBoxFilePickerWhenAvailable = false
        }
        // `unfocus()` force-disables active state to stop stale retries from stealing focus.
        // Re-enable it immediately for explicit focus requests (socket/UI) so ensureFocus can run.
        hostedView.preparePanelFocusIntentForActivation(.surface)
        hostedView.setActive(true)
        guard let focusWindow = surface.uiWindow ?? hostedView.window else {
            surface.setFocus(false)
            return false
        }
        guard AppDelegate.shared?.allowsTerminalKeyboardFocus(
            workspaceId: workspaceId,
            panelId: id,
            in: focusWindow
        ) != false else {
            surface.setFocus(false)
            return false
        }
        surface.setFocus(true)
        hostedView.ensureFocus(
            for: workspaceId,
            surfaceId: id,
            respectForeignFirstResponder: respectForeignFirstResponder,
            focusTransactionId: focusTransactionId
        )
        return true
    }

    func unfocus() {
        surface.setFocus(false)
        shouldFocusTextBoxWhenAvailable = false
        shouldOpenTextBoxFilePickerWhenAvailable = false
        shouldHideTextBoxOnNextEscape = false
        // Cancel any pending focus work items so an inactive terminal can't steal first responder
        // back from another surface (notably WKWebView) during rapid focus changes in tests.
        //
        // Also flip the hosted view's active state immediately: SwiftUI focus propagation can lag
        // by a runloop tick, and `requestFocus` retries that are already executing can otherwise
        // schedule new work items that fire after we navigate away.
        hostedView.setActive(false)
    }

    func close() {
        isClosingPanel = true
        discardTextBoxContentForClose()
        removeOwnedSessionScrollbackReplayArtifact()
        // Detach from the window portal on real close so stale hosted views
        // cannot remain above browser panes after split close.
        surface.beginPortalCloseLifecycle(reason: "panel.close")
#if DEBUG
        let frame = String(format: "%.1fx%.1f", hostedView.frame.width, hostedView.frame.height)
        let bounds = String(format: "%.1fx%.1f", hostedView.bounds.width, hostedView.bounds.height)
        cmuxDebugLog(
            "surface.panel.close.begin panel=\(id.uuidString.prefix(5)) " +
            "workspace=\(workspaceId.uuidString.prefix(5)) runtimeSurface=\(surface.surface != nil ? 1 : 0) " +
            "inWindow=\(surface.isViewInWindow ? 1 : 0) hasSuperview=\(hostedView.superview != nil ? 1 : 0) " +
            "hidden=\(hostedView.isHidden ? 1 : 0) frame=\(frame) bounds=\(bounds)"
        )
#endif
        unfocus()
        hostedView.setVisibleInUI(false)
        TerminalWindowPortalRegistry.detach(hostedView: hostedView)
#if DEBUG
        cmuxDebugLog(
            "surface.panel.close.end panel=\(id.uuidString.prefix(5)) " +
            "inWindow=\(surface.isViewInWindow ? 1 : 0) hasSuperview=\(hostedView.superview != nil ? 1 : 0) " +
            "hidden=\(hostedView.isHidden ? 1 : 0)"
        )
#endif
        surface.teardownSurface()
    }

    func enterAgentHibernation(
        agent: SessionRestorableAgentSnapshot,
        lastActivityAt: Date,
        hibernatedAt: Date = Date()
    ) {
        agentHibernationState = AgentHibernationPanelState(
            agent: agent,
            hibernatedAt: hibernatedAt,
            lastActivityAt: lastActivityAt
        )
        unfocus()
        searchState = nil
        hostedView.setVisibleInUI(false)
        TerminalWindowPortalRegistry.detach(hostedView: hostedView)
        surface.suspendRuntimeSurfaceForAgentHibernation(reason: "agentHibernation")
        requestViewReattach()
    }

    @discardableResult
    func prepareAgentHibernationResume() -> AgentHibernationResumePreparation {
        guard let state = agentHibernationState else {
            return .unavailable
        }
        let resumeStartupInput = state.agent.resumeStartupInput()
        agentHibernationState = nil
        surface.prepareAgentHibernationResume(initialInput: resumeStartupInput)
        requestViewReattach()
        surface.requestBackgroundSurfaceStartIfNeeded()
        return .resumed(queuedStartupInput: resumeStartupInput != nil)
    }

    func requestViewReattach() {
        viewReattachToken &+= 1
    }

    /// Monotonic model ownership epoch across container transfers and local
    /// representable reattachments. This takes precedence over host creation
    /// order when a move rolls back to an earlier view.
    var portalHostOwnershipGeneration: UInt64 {
        surface.currentPortalHostOwnershipGeneration() &+ viewReattachToken
    }

    func recordPortalHostOwnershipChange() {
        requestViewReattach()
    }

    // MARK: - Terminal-specific methods

    @discardableResult
    func sendText(_ text: String) -> Bool {
        resumeForExplicitInputIfNeeded()
        return surface.sendText(text)
    }

    func sendInput(_ text: String) {
        _ = sendInputResult(text)
    }

    @discardableResult
    func sendInputResult(_ text: String) -> TerminalSurface.InputSendResult {
        resumeForExplicitInputIfNeeded()
        return surface.sendInputResult(text)
    }

    @discardableResult
    func sendNamedKeyResult(_ keyName: String) -> TerminalSurface.NamedKeySendResult {
        resumeForExplicitInputIfNeeded()
        return surface.sendNamedKey(keyName)
    }

    @discardableResult
    func sendNamedKey(_ keyName: String) -> Bool {
        switch sendNamedKeyResult(keyName) {
        case .sent, .queued:
            return true
        case .unknownKey, .inputQueueFull, .surfaceUnavailable, .processExited:
            return false
        }
    }

    func performBindingAction(_ action: String) -> Bool {
        guard !isAgentHibernated else { return false }
        return surface.performExplicitInputBindingAction(action)
    }

    @discardableResult
    func clearScreenKeepingScrollback() -> Bool {
        clearScreenKeepingScrollbackResult().accepted
    }

    /// Clears through the shared Ctrl-L input path while preserving whether the
    /// keystroke was sent, queued, or rejected.
    func clearScreenKeepingScrollbackResult() -> TerminalSurface.NamedKeySendResult {
        resumeForExplicitInputIfNeeded()
        return surface.clearScreenKeepingScrollbackResult()
    }

    private func resumeForExplicitInputIfNeeded() {
        guard isAgentHibernated else { return }
        _ = requestAgentHibernationResume(focus: false)
    }

    @discardableResult
    private func requestAgentHibernationResume(focus: Bool) -> Bool {
        guard isAgentHibernated else { return false }
        if let onRequestAgentHibernationResume {
            return onRequestAgentHibernationResume(focus)
        }
        return prepareAgentHibernationResume().didResume
    }

    func hasSelection() -> Bool {
        surface.hasSelection()
    }

    func needsConfirmClose() -> Bool {
        surface.needsConfirmClose()
    }

    func shouldPersistScrollbackForSessionSnapshot() -> Bool {
        // Session restore only replays terminal output into a fresh shell. If Ghostty
        // says we are not safely at a prompt, replaying that state later is misleading.
        !surface.needsConfirmClose()
    }

    func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        guard NotificationPaneFlashSettings.isEnabled() else { return }

        switch TmuxOverlayExperimentSettings.target() {
        case .bonsplitPane:
            if let onRequestWorkspacePaneFlash {
                onRequestWorkspacePaneFlash(reason)
                return
            }
            hostedView.triggerFlash(style: GhosttySurfaceScrollView.flashStyle(for: reason))
        case .surface, .tmuxActivePane:
            hostedView.triggerFlash(style: GhosttySurfaceScrollView.flashStyle(for: reason))
        }
    }

    func triggerNotificationDismissFlash() {
        triggerFlash(reason: .notificationDismiss)
    }

    func applyWindowBackgroundIfActive() {
        surface.applyWindowBackgroundIfActive()
    }

    func captureFocusIntent(in window: NSWindow?) -> PanelFocusIntent {
        guard !isAgentHibernated else { return .panel }
        if textBoxOwnsResponder(window?.firstResponder) {
            return .terminal(.textBoxInput)
        }
        return .terminal(hostedView.capturePanelFocusIntent(in: window))
    }

    func preferredFocusIntentForActivation() -> PanelFocusIntent {
        guard !isAgentHibernated else { return .panel }
        if isTextBoxActive, textBoxInputFocusIntent == .textBox {
            return .terminal(.textBoxInput)
        }
        return .terminal(hostedView.preferredPanelFocusIntentForActivation())
    }

    func prepareFocusIntentForActivation(_ intent: PanelFocusIntent) {
        guard !isAgentHibernated else { return }
        guard case .terminal(let target) = intent else { return }
        switch target {
        case .surface, .findField:
            if isTextBoxActive {
                textBoxInputFocusIntent = .terminal
                shouldFocusTextBoxWhenAvailable = false
            }
            hostedView.preparePanelFocusIntentForActivation(target)
        case .textBoxInput:
            textBoxInputFocusIntent = .textBox
            isTextBoxActive = true
            shouldFocusTextBoxWhenAvailable = true
        }
    }

    @discardableResult
    func restoreFocusIntent(_ intent: PanelFocusIntent) -> Bool {
        if isAgentHibernated {
            return requestAgentHibernationResume(focus: true)
        }
        switch intent {
        case .panel:
            focus()
            return true
        case .terminal(let target):
            switch target {
            case .surface:
                return focusTerminalSurface(respectForeignFirstResponder: false)
            case .textBoxInput:
                return focusTextBoxInput()
            case .findField:
                return hostedView.restorePanelFocusIntent(target)
            }
        default:
            return false
        }
    }

    func ownedFocusIntent(for responder: NSResponder, in window: NSWindow) -> PanelFocusIntent? {
        guard !isAgentHibernated else { return nil }
        _ = window
        if textBoxOwnsResponder(responder) {
            return .terminal(.textBoxInput)
        }
        guard let intent = hostedView.ownedPanelFocusIntent(for: responder) else { return nil }
        return .terminal(intent)
    }

    @discardableResult
    func yieldFocusIntent(_ intent: PanelFocusIntent, in window: NSWindow) -> Bool {
        guard !isAgentHibernated else { return false }
        guard case .terminal(let target) = intent else { return false }
        if target == .textBoxInput {
            guard let firstResponder = window.firstResponder,
                  textBoxOwnsResponder(firstResponder) else {
                return false
            }
            surface.setFocus(false)
            window.makeFirstResponder(nil)
            return true
        }
        return hostedView.yieldPanelFocusIntent(target, in: window)
    }

    private func textBoxOwnsResponder(_ responder: NSResponder?) -> Bool {
        guard let responder,
              let textBoxInputView else { return false }
        if responder === textBoxInputView {
            return true
        }
        guard let view = responder as? NSView else { return false }
        return view.isDescendant(of: textBoxInputView)
    }

    private func textBoxOrSurfaceOwnsResponder(in window: NSWindow?) -> Bool {
        guard let window else { return false }
        if window === hostedView.window,
           hostedView.isSurfaceViewFirstResponder() {
            return true
        }
        guard let responder = window.firstResponder else { return false }
        if textBoxOwnsResponder(responder) {
            return true
        }
        return hostedView.ownedPanelFocusIntent(for: responder) == .surface
    }

    private func textBoxOrSurfaceOwnsEscapeContext(in window: NSWindow?) -> Bool {
        guard let window else { return false }
        return textBoxOrSurfaceOwnsResponder(in: window)
    }
}
