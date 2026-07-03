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

    @Test func admitsSingleOversizedPayloadOntoIdleBuffer() {
        // A foreground paste larger than the cap (e.g. a big clipboard) must be
        // delivered in one FIFO send, not rejected — rejection disconnects the
        // mobile terminal. The cap only bounds accumulation once a backlog exists.
        var buffer = MobileTerminalInputSendBuffer()
        let workspaceID = MobileWorkspacePreview.ID(rawValue: "workspace-a")
        let terminalID = MobileTerminalPreview.ID(rawValue: "terminal-a")
        let oversizedPaste = String(
            repeating: "a",
            count: MobileTerminalInputSendBuffer.maximumPendingByteCount * 2 + 1
        )

        #expect(
            buffer.enqueue(oversizedPaste, workspaceID: workspaceID, terminalID: terminalID)
                == .startDraining
        )
        #expect(buffer.pendingByteCount == oversizedPaste.utf8.count)
        // While the oversized paste is still pending, the cap is back in force:
        // further input that would grow the backlog is rejected (back-pressure).
        #expect(buffer.enqueue("b", workspaceID: workspaceID, terminalID: terminalID) == .rejected)

        let batch = buffer.nextBatch()
        #expect(batch?.text == oversizedPaste)
        #expect(buffer.pendingByteCount == 0)
        // Once drained, the idle buffer admits input again.
        #expect(buffer.enqueue("b", workspaceID: workspaceID, terminalID: terminalID) == .queued)
        #expect(buffer.nextBatch()?.text == "b")
        #expect(buffer.nextBatch() == nil)
    }

    @Test func rejectsOversizedPayloadWhilePreviousBatchIsInFlight() {
        var buffer = MobileTerminalInputSendBuffer()
        let workspaceID = MobileWorkspacePreview.ID(rawValue: "workspace-a")
        let terminalID = MobileTerminalPreview.ID(rawValue: "terminal-a")
        let oversizedPaste = String(
            repeating: "a",
            count: MobileTerminalInputSendBuffer.maximumPendingByteCount * 2 + 1
        )

        #expect(
            buffer.enqueue(oversizedPaste, workspaceID: workspaceID, terminalID: terminalID)
                == .startDraining
        )
        #expect(buffer.nextBatch()?.text == oversizedPaste)
        #expect(buffer.pendingByteCount == 0)
        #expect(buffer.isDraining)

        #expect(
            buffer.enqueue(oversizedPaste, workspaceID: workspaceID, terminalID: terminalID)
                == .rejected
        )
        #expect(buffer.pendingByteCount == 0)
        #expect(buffer.enqueue("b", workspaceID: workspaceID, terminalID: terminalID) == .queued)
        #expect(buffer.nextBatch()?.text == "b")
        #expect(buffer.nextBatch() == nil)
    }
}
