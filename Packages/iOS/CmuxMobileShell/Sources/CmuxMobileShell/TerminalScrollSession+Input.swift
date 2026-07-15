import Foundation

extension TerminalScrollSession {
    struct InputTransaction {
        let id: UUID
        var input: TerminalInputIntent
        let receipt: TerminalInteractionReceipt
        let snapGeneration: UInt64
        var epoch: UInt64?
        var submissionCount: Int
        private var textBytes: Data?

        init(
            id: UUID = UUID(),
            input: TerminalInputIntent,
            receipt: TerminalInteractionReceipt,
            snapGeneration: UInt64,
            epoch: UInt64? = nil
        ) {
            self.id = id
            self.receipt = receipt
            self.snapGeneration = snapGeneration
            self.epoch = epoch
            self.submissionCount = 1
            if case .text(let text, let workspaceID) = input {
                self.input = .text("", workspaceID: workspaceID)
                self.textBytes = Data(text.utf8)
            } else {
                self.input = input
                self.textBytes = nil
            }
        }

        var bufferedByteCount: Int {
            textBytes?.count ?? input.bufferedByteCount
        }

        var inputForSend: TerminalInputIntent {
            guard let textBytes,
                  case .text(_, let workspaceID) = input else { return input }
            return .text(String(decoding: textBytes, as: UTF8.self), workspaceID: workspaceID)
        }

        mutating func appendCompatibleText(
            _ newer: TerminalInputIntent,
            maximumByteCount: Int
        ) -> Bool {
            guard case .text(_, let workspaceID) = input,
                  case .text(let newerText, let newerWorkspaceID) = newer,
                  workspaceID == newerWorkspaceID,
                  var textBytes else { return false }
            let newerByteCount = newerText.utf8.count
            guard newerByteCount <= maximumByteCount - textBytes.count else { return false }
            textBytes.append(contentsOf: newerText.utf8)
            self.textBytes = textBytes
            submissionCount += 1
            return true
        }
    }

    func submitInput(_ input: TerminalInputIntent) -> TerminalInteractionReceipt {
        cancelLocal()
        if let coalescedReceipt = coalesceQueuedTextInput(input) {
            return coalescedReceipt
        }

        let receipt = TerminalInteractionReceipt()
        let transaction = InputTransaction(
            input: input,
            receipt: receipt,
            snapGeneration: bottomSnapGeneration
        )
        recordBottomSnapAdmission(transaction.snapGeneration)
        if case .idle = phase, intents.count == 0 {
            startInput(transaction)
            return receipt
        }
        guard transaction.bufferedByteCount <= Self.maximumQueuedInputByteCount - queuedInputByteCount,
              queuedInteractionCount < Self.maximumQueuedInteractionCount,
              intents.append(.input(transaction)) else {
            receipt.resolve(false)
            inputBufferDidReject(queuedInputByteCount)
            return receipt
        }
        queuedInteractionCount += 1
        queuedInputByteCount += transaction.bufferedByteCount
        startNextIntentIfIdle()
        return receipt
    }

    private func coalesceQueuedTextInput(
        _ input: TerminalInputIntent
    ) -> TerminalInteractionReceipt? {
        guard case .text(let text, _) = input, !text.isEmpty else { return nil }
        var compatibleTail = false
        var receipt: TerminalInteractionReceipt?
        let merged = intents.mutateLast { intent in
            guard case .input(var transaction) = intent,
                  transaction.isCompatibleText(input) else { return false }
            compatibleTail = true
            let remainingByteCount = max(
                0,
                Self.maximumQueuedInputByteCount - queuedInputByteCount
            )
            guard transaction.appendCompatibleText(
                input,
                maximumByteCount: transaction.bufferedByteCount + remainingByteCount
            ) else { return false }
            receipt = transaction.receipt
            intent = .input(transaction)
            return true
        }
        if merged {
            queuedInputByteCount += input.bufferedByteCount
            return receipt
        }
        guard compatibleTail else { return nil }
        let rejected = TerminalInteractionReceipt()
        rejected.resolve(false)
        inputBufferDidReject(queuedInputByteCount)
        return rejected
    }

    func startInput(_ input: InputTransaction) {
        prepareInput()
        var transaction = input
        transaction.epoch = advanceToNextInputEpoch(submissionCount: input.submissionCount)
        guard input.snapGeneration > consumedBottomSnapGeneration else {
            startInputSend(transaction)
            return
        }
        lastDirectionLines = 1
        let receipt = enqueueScrollToBottom()
        phase = .inputSnap(transaction)
        inputTask = Task { @MainActor [weak self] in
            let applied = await receipt.value
            guard !Task.isCancelled else { return }
            self?.inputSnapDidComplete(
                id: transaction.id,
                generation: transaction.snapGeneration,
                applied: applied
            )
        }
    }

    private func advanceToNextInputEpoch(submissionCount: Int) -> UInt64 {
        interactionEpoch = advanceInputEpoch(max(1, submissionCount))
        latestClientRevision = 0
        latestLocallyAppliedRevision = 0
        latestReconciledRevision = 0
        accumulatedRowsSincePrefetch = 0
        hasPrimedPrefetch = false
        return interactionEpoch
    }

    private func inputSnapDidComplete(id: UUID, generation: UInt64, applied: Bool) {
        guard case .inputSnap(let transaction) = phase, transaction.id == id else { return }
        inputTask = nil
        if applied {
            consumedBottomSnapGeneration = max(consumedBottomSnapGeneration, generation)
        }
        startInputSend(transaction)
    }

    private func startInputSend(_ transaction: InputTransaction) {
        guard let epoch = transaction.epoch else {
            transaction.receipt.resolve(false)
            phase = .idle
            startNextIntentIfIdle()
            return
        }
        if case .fence = transaction.input {
            transaction.receipt.resolve(true)
            phase = .idle
            startNextIntentIfIdle()
            return
        }
        phase = .inputSend(transaction)
        inputTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let succeeded = await self.sendInput(
                self.surfaceID,
                epoch,
                transaction.inputForSend
            )
            guard !Task.isCancelled else { return }
            self.inputDidComplete(id: transaction.id, succeeded: succeeded)
        }
    }

    private func inputDidComplete(id: UUID, succeeded: Bool) {
        guard case .inputSend(let transaction) = phase, transaction.id == id else { return }
        inputTask = nil
        transaction.receipt.resolve(succeeded)
        phase = .idle
        startNextIntentIfIdle()
    }
}

private extension TerminalScrollSession.InputTransaction {
    func isCompatibleText(_ newer: TerminalInputIntent) -> Bool {
        guard case .text(_, let workspaceID) = input,
              case .text(_, let newerWorkspaceID) = newer else { return false }
        return workspaceID == newerWorkspaceID
    }
}
