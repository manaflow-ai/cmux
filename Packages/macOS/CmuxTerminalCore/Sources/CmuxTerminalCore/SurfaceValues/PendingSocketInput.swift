public import Foundation

/// One unit of socket-delivered input queued for a not-yet-started surface.
public enum PendingSocketInput: Sendable {
    /// Text delivered through the paste path once the surface starts.
    case pasteText(Data)
    /// Text delivered through the committed-text input path.
    case inputText(Data)
    /// Text delivered through the committed-text input path on behalf of an
    /// app-owned control, without human composer ownership.
    case appOwnedInputText(Data)
    /// Bytes that must be processed as terminal output, not user input.
    case processOutput(Data)
    /// A named-key press to replay.
    case key(PendingKeyEvent)
    /// A named-key press owned by an app control, not a human composer.
    case appOwnedKey(PendingKeyEvent)
    /// One indivisible composed prompt: app-owned preparation keys followed by
    /// bracketed-paste text and its agent-aware submit key. Hook attribution is
    /// carried with the queued transaction but is not recorded until the item
    /// is actually flushed.
    case promptSubmission(
        preparationKeys: [PendingKeyEvent],
        text: Data,
        submitKey: PendingKeyEvent,
        hookRecordingSource: String?,
        hookConfirmedHumanInputSnapshot:
            TerminalPromptInputLedger.HumanInputSnapshot?,
        agentInputScope: String?,
        deliveryReceipt: PromptSubmissionDeliveryReceipt?
    )
    /// One indivisible prompt submitted by a human-owned mobile composer.
    case humanPromptSubmission(
        preparationKeys: [PendingKeyEvent],
        text: Data,
        submitKey: PendingKeyEvent
    )
    /// Raw key text to replay as one Ghostty key event.
    case keyText(String)

    /// The byte cost this entry contributes to the pending-input budget.
    public var estimatedBytes: Int {
        switch self {
        case .pasteText(let data),
             .inputText(let data),
             .appOwnedInputText(let data),
             .processOutput(let data):
            return data.count
        case .key(let event), .appOwnedKey(let event):
            return event.queuedByteCost
        case .promptSubmission(
            let preparationKeys,
            let text,
            let submitKey,
            _,
            _,
            _,
            _
        ):
            // `text` is already UTF-8 ``Data``; `Data.count` is the exact
            // byte cost used by the pending-input budget.
            return preparationKeys.reduce(
                text.count + submitKey.queuedByteCost
            ) { byteCount, event in
                byteCount + event.queuedByteCost
            }
        case .humanPromptSubmission(
            let preparationKeys,
            let text,
            let submitKey
        ):
            // `text` is UTF-8 ``Data``, so its count is already bytes.
            return preparationKeys.reduce(
                text.count + submitKey.queuedByteCost
            ) { byteCount, event in
                byteCount + event.queuedByteCost
            }
        case .keyText(let text):
            return max(text.utf8.count, 1)
        }
    }

    /// Whether replaying this item can mutate a human-owned composer.
    ///
    /// Compound prompt submissions and terminal-output bytes are app-owned;
    /// the ordinary text/key cases retain the conservative human ownership
    /// policy used by the prompt ledger.
    public var isHumanInput: Bool {
        switch self {
        case .pasteText, .inputText, .key, .keyText:
            true
        case .appOwnedInputText,
             .appOwnedKey,
             .processOutput,
             .promptSubmission:
            false
        case .humanPromptSubmission:
            true
        }
    }

    /// Completes a queued compound prompt's optional delivery receipt.
    ///
    /// Surface teardown uses this value-only hook from its nonisolated
    /// deinitializer, where it cannot call a MainActor helper. Other input
    /// kinds have no receipt and are left unchanged.
    public func completePromptSubmissionDelivery(
        with result: PromptSubmissionSendResult
    ) {
        guard case .promptSubmission(
            _, _, _, _, _, _, let deliveryReceipt
        ) = self else {
            return
        }
        deliveryReceipt?.finish(result)
    }

    /// Whether a queued compound prompt was cancelled before replay.
    public var isCancelledPromptSubmission: Bool {
        guard case .promptSubmission(
            _, _, _, _, _, _, let deliveryReceipt
        ) = self else {
            return false
        }
        return deliveryReceipt?.isCancelled == true
    }
}
