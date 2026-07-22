import AppKit
import CMUXAgentLaunch

extension TextBoxInputContainer {
    func submit() {
        let textView = textViewReference.textView
        guard TextBoxSubmitAvailability.shouldSubmit(
            hasPendingAttachmentUpload: textView?.hasPendingAttachmentUploadPlaceholder() ?? hasPendingAttachmentUpload,
            hasMarkedText: textView?.hasMarkedText() ?? hasMarkedText
        ) else {
            NSSound.beep()
            return
        }
        let submittedParts = textView?.submissionParts()
            ?? [TextBoxSubmissionPart.text(text.trimmingCharacters(in: .newlines))]
        let poolWorkspaceId = surface.owningWorkspace()?.id
        let hasTypedContent = TextBoxSubmissionFormatter.hasSubmittableContent(submittedParts)
        guard hasTypedContent || pendingCommentCount > 0 else {
            NSSound.beep()
            return
        }
        if isPendingProviderLaunchAwaitingAgent {
            NSSound.beep()
            return
        }
        let launchAction = effectiveSubmitAction
        if Self.shouldFailClosedForCommandTemplate(
            action: launchAction,
            shouldForceTextEntrySubmit: shouldForceTextEntrySubmit,
            allowsCommandTemplateSubmit: allowsCommandTemplateSubmit
        ) {
            NSSound.beep()
            return
        }
        if let launchCommand = providerLaunchCommand(for: launchAction) {
            switch onGuardedAgentLaunch(launchCommand, .launchOnly) {
            case .launched:
                startPendingProviderLaunch(launchAction)
                onRecordLaunchCommand(launchAction.launchContextCommand() ?? launchCommand)
            case .suppressed(let reason):
                NSLog("[AgentLaunch] suppressed TextBox launch: %@", String(describing: reason))
                NSSound.beep()
            case .promptRerouted:
                NSSound.beep()
            case .failed(let code):
                NSLog("[AgentLaunch] TextBox launch failed: %@", code)
                NSSound.beep()
            }
            return
        }
        let pendingComments = poolWorkspaceId.map {
            DiffCommentSubmissionPool.shared.consumeAll(workspaceId: $0)
        } ?? []
        var partsToSend = submittedParts
        if !pendingComments.isEmpty {
            let bundle = pendingComments.map(\.submissionText).joined(separator: "\n")
            partsToSend.append(TextBoxSubmissionPart.text(hasTypedContent ? "\n\n" + bundle : bundle))
        }
        let submittedTextView = textView
        let preservedContent = submittedTextView?.attributedContentForPreservation()
        submittedTextView?.prepareForSubmit()
        submittedTextView?.clearContent(cleanupAttachmentFiles: false)
        text = ""
        attachments = []
        hasPendingAttachmentUpload = false
        textViewHeight = 0
        let rollbackSnapshot = TextBoxFailedSubmitRollbackSnapshot(
            revision: advanceContentRevision(),
            text: "",
            attachmentCount: 0
        )
        let submitPlan = dispatchPlan(partsToSend, applying: effectiveSubmitAction)
        let shouldRouteThroughAgentPrompt = launchAction.kind == .textEntry
            && TextBoxAgentDetection.supportsActiveAgentPrefixes(context: terminalAgentContext)
            && partsToSend.allSatisfy { part in
                if case .text = part { return true }
                return false
            }
        let handleCompletion: (TextBoxSubmit.CompletionContext) -> Void = { completionContext in
            guard completionContext.didSubmit else {
                if submitPlan.launchContextCommand != nil {
                    clearPendingProviderLaunch()
                    onClearLaunchCommand()
                }
                if let poolWorkspaceId, !pendingComments.isEmpty {
                    DiffCommentSubmissionPool.shared.restorePending(
                        pendingComments,
                        workspaceId: poolWorkspaceId
                    )
                }
                guard TextBoxFailedSubmitRollbackPolicy.shouldRestore(
                    rollbackSnapshot: rollbackSnapshot,
                    currentSnapshot: currentRollbackSnapshot()
                ) else {
                    NSSound.beep()
                    return
                }
                if let preservedContent {
                    submittedTextView?.installPreservedContent(preservedContent)
                } else {
                    text = TextBoxSubmissionFormatter.formattedText(from: submittedParts)
                    attachments = submittedParts.compactMap { part in
                        if case .attachment(let attachment) = part { return attachment }
                        return nil
                    }
                }
                NSSound.beep()
                return
            }
            if !pendingComments.isEmpty {
                for (repoRoot, entries) in Dictionary(grouping: pendingComments, by: \.repoRoot) {
                    DiffCommentStore.shared.markConsumed(ids: entries.map(\.commentId), repoRoot: repoRoot)
                }
            }
            resetPanelSubmitActionAfterSuccessfulSubmit(submittedAction: launchAction)
            let submittedAttachments = submittedParts.compactMap { part -> TextBoxAttachment? in
                if case .attachment(let attachment) = part { return attachment }
                return nil
            }
            submittedTextView?.cleanupCopiedDraftFilesForPreservedLocalPathSubmissions(submittedAttachments)
            let cleanupAttachments = TextBoxSubmit.cleanupAttachmentsAfterSubmit(
                from: submittedParts,
                terminalAgentContext: submitPlan.cleanupTerminalAgentContext,
                completionContext: completionContext
            )
            submittedTextView?.cleanupDisposableAttachmentFiles(cleanupAttachments)
        }
        if let launchCommand = submitPlan.launchCommand,
           let launchContextCommand = submitPlan.launchContextCommand {
            let prompt = TextBoxSubmissionFormatter.formattedText(from: partsToSend)
            let result = onGuardedAgentLaunch(
                launchCommand,
                .launchThenSubmitPrompt(prompt)
            )
            switch result {
            case .launched:
                startPendingProviderLaunch(launchAction)
                onRecordLaunchCommand(launchContextCommand)
                handleCompletion(.empty)
            case .promptRerouted:
                handleCompletion(.empty)
            case .suppressed(let reason):
                NSLog("[AgentLaunch] suppressed TextBox prompt launch: %@", String(describing: reason))
                handleCompletion(.init(failure: .terminalWriteRejected))
            case .failed(let code):
                NSLog("[AgentLaunch] TextBox prompt launch failed: %@", code)
                handleCompletion(.init(failure: .terminalWriteRejected))
            }
            return
        }
        if shouldRouteThroughAgentPrompt {
            let prompt = TextBoxSubmissionFormatter.formattedText(from: partsToSend)
            switch onSubmitAgentPrompt(prompt) {
            case .accepted, .queued:
                handleCompletion(.empty)
            case .failed(let code):
                NSLog("[AgentPrompt] TextBox prompt failed: %@", code)
                handleCompletion(.init(failure: .terminalWriteRejected))
            }
            return
        }
        TextBoxSubmit.sendEvents(
            submitPlan.events,
            via: surface,
            onComplete: handleCompletion
        )
    }
}
