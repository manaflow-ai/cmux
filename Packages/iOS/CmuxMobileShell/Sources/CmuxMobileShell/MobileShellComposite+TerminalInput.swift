internal import CmuxMobileShellModel
public import Foundation
internal import OSLog

private let terminalInputLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "dev.cmux.ios",
    category: "mobile-shell"
)

extension MobileShellComposite {
    public func sendTerminalRawInput(_ text: String) {
        #if DEBUG
        terminalInputLog.debug("enqueue raw terminal input byteCount=\(text.utf8.count, privacy: .public)")
        #endif
        guard let workspaceID = selectedWorkspace?.id,
              let terminalID = selectedTerminalID else {
            #if DEBUG
            terminalInputLog.info("skip raw terminal input enqueue selectedWorkspace=\(self.selectedWorkspace == nil ? 0 : 1, privacy: .public) selectedTerminal=\(self.selectedTerminalID == nil ? 0 : 1, privacy: .public)")
            #endif
            return
        }
        enqueueRawTerminalInput(text, workspaceID: workspaceID, terminalID: terminalID)
    }

    /// Queue raw bytes to the surface that produced them.
    ///
    /// The iOS terminal view calls this synchronously from its UIKit input
    /// delegate so bytes enter the FIFO in the exact order UIKit emits them.
    public func sendTerminalRawInput(_ data: Data, surfaceID: String) {
        guard let input = rawTerminalInput(textData: data, surfaceID: surfaceID) else { return }
        enqueueRawTerminalInput(
            input.text,
            workspaceID: input.workspaceID,
            terminalID: input.terminalID
        )
    }

    /// Submit raw text to the currently selected terminal when one is available.
    public func submitTerminalRawInput(_ text: String) async {
        guard !text.isEmpty else { return }
        guard let workspaceID = selectedWorkspace?.id,
              let terminalID = selectedTerminalID else {
            return
        }
        let drainTask = enqueueRawTerminalInput(
            text,
            workspaceID: workspaceID,
            terminalID: terminalID
        )
        await drainTask?.value
    }

    /// Raw-bytes overload. The libghostty render path on iOS uses this
    /// for input that may include binary sequences (mouse reports,
    /// kitty keyboard, IME byte streams). The wire RPC encodes bytes
    /// as the UTF-8-stringified payload of `mobile.terminal.input`,
    /// then the Mac decodes back to Data. If we ever need true binary
    /// fidelity (paste of mid-codepoint bytes, etc.), upgrade the
    /// `input` param to a base64 field.
    public func submitTerminalRawInput(_ data: Data, surfaceID: String) async {
        guard let input = rawTerminalInput(textData: data, surfaceID: surfaceID) else { return }
        let drainTask = enqueueRawTerminalInput(
            input.text,
            workspaceID: input.workspaceID,
            terminalID: input.terminalID
        )
        await drainTask?.value
    }

    func clearRawTerminalInputBuffer() {
        rawTerminalInputDrainTask?.cancel()
        rawTerminalInputDrainTask = nil
        rawTerminalInputDrainTaskID = nil
        rawTerminalInputBuffer.clear()
    }

    private func rawTerminalInput(
        textData data: Data,
        surfaceID: String
    ) -> (
        text: String,
        workspaceID: MobileWorkspacePreview.ID,
        terminalID: MobileTerminalPreview.ID
    )? {
        guard !data.isEmpty else { return nil }
        guard let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        let workspaceCandidate = workspaces.first(where: { workspace in
            workspace.terminals.contains(where: { $0.id.rawValue == surfaceID })
        })
        guard let workspace = workspaceCandidate else { return nil }
        return (
            text: text,
            workspaceID: workspace.id,
            terminalID: MobileTerminalPreview.ID(rawValue: surfaceID)
        )
    }

    @discardableResult
    private func enqueueRawTerminalInput(
        _ text: String,
        workspaceID: MobileWorkspacePreview.ID,
        terminalID: MobileTerminalPreview.ID
    ) -> Task<Void, Never>? {
        switch rawTerminalInputBuffer.enqueue(
            text,
            workspaceID: workspaceID,
            terminalID: terminalID
        ) {
        case .startDraining:
            return startRawTerminalInputDrainTask()
        case .queued:
            return rawTerminalInputDrainTask
        case .rejected:
            handleRawTerminalInputQueueRejected()
            return nil
        }
    }

    private func startRawTerminalInputDrainTask() -> Task<Void, Never> {
        let taskID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.drainRawTerminalInputBuffer(taskID: taskID)
        }
        rawTerminalInputDrainTaskID = taskID
        rawTerminalInputDrainTask = task
        return task
    }

    private func drainRawTerminalInputBuffer(taskID: UUID) async {
        defer {
            if rawTerminalInputDrainTaskID == taskID {
                rawTerminalInputDrainTask = nil
                rawTerminalInputDrainTaskID = nil
            }
        }
        while !Task.isCancelled, let chunk = rawTerminalInputBuffer.nextBatch() {
            await submitTerminalRawInput(
                chunk.text,
                workspaceID: chunk.workspaceID,
                terminalID: chunk.terminalID
            )
        }
    }
}
