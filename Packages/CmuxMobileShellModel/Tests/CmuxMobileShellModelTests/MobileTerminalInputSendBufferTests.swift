import Testing

@testable import CmuxMobileShellModel

@Suite struct MobileTerminalInputSendBufferTests {
    @Test func batchesPendingInputInOrder() {
        var buffer = MobileTerminalInputSendBuffer()
        let workspaceA = MobileWorkspacePreview.ID(rawValue: "workspace-a")
        let terminalA = MobileTerminalPreview.ID(rawValue: "terminal-a")
        let terminalB = MobileTerminalPreview.ID(rawValue: "terminal-b")

        let startsDrain = buffer.enqueue("p", workspaceID: workspaceA, terminalID: terminalA)
        let appendsWhileDraining = buffer.enqueue("rint", workspaceID: workspaceA, terminalID: terminalA)
        let appendsFinalCharacter = buffer.enqueue("f", workspaceID: workspaceA, terminalID: terminalA)
        #expect(startsDrain == .startDraining)
        #expect(appendsWhileDraining == .queued)
        #expect(appendsFinalCharacter == .queued)
        let firstBatch = buffer.nextBatch()
        #expect(firstBatch?.workspaceID == workspaceA)
        #expect(firstBatch?.terminalID == terminalA)
        #expect(firstBatch?.text == "printf")

        let appendsSecondBatch = buffer.enqueue(" 'one'", workspaceID: workspaceA, terminalID: terminalA)
        #expect(appendsSecondBatch == .queued)
        #expect(buffer.nextBatch()?.text == " 'one'")
        #expect(buffer.nextBatch() == nil)

        let restartsDrain = buffer.enqueue("\r", workspaceID: workspaceA, terminalID: terminalB)
        #expect(restartsDrain == .startDraining)
        let terminalBBatch = buffer.nextBatch()
        #expect(terminalBBatch?.terminalID == terminalB)
        #expect(terminalBBatch?.text == "\r")
    }

    @Test func rejectsOverflowUntilPendingInputDrains() {
        var buffer = MobileTerminalInputSendBuffer()
        let workspaceID = MobileWorkspacePreview.ID(rawValue: "workspace-a")
        let terminalID = MobileTerminalPreview.ID(rawValue: "terminal-a")
        let fullBufferText = String(repeating: "a", count: MobileTerminalInputSendBuffer.maximumPendingByteCount)

        #expect(buffer.enqueue(fullBufferText, workspaceID: workspaceID, terminalID: terminalID) == .startDraining)
        #expect(buffer.pendingByteCount == MobileTerminalInputSendBuffer.maximumPendingByteCount)
        #expect(buffer.enqueue("b", workspaceID: workspaceID, terminalID: terminalID) == .rejected)
        #expect(buffer.pendingByteCount == MobileTerminalInputSendBuffer.maximumPendingByteCount)

        let batch = buffer.nextBatch()
        #expect(batch?.text == fullBufferText)
        #expect(buffer.pendingByteCount == 0)
        #expect(buffer.enqueue("b", workspaceID: workspaceID, terminalID: terminalID) == .queued)
        #expect(buffer.nextBatch()?.text == "b")
        #expect(buffer.nextBatch() == nil)
        #expect(buffer.enqueue("c", workspaceID: workspaceID, terminalID: terminalID) == .startDraining)
    }
}
