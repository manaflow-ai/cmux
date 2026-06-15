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

    @Test func acceptsSingleOversizedInputWhenNoBacklogAndDrainsInBoundedBatches() {
        var buffer = MobileTerminalInputSendBuffer()
        let workspaceID = MobileWorkspacePreview.ID(rawValue: "workspace-a")
        let terminalID = MobileTerminalPreview.ID(rawValue: "terminal-a")
        let oversizedText = String(repeating: "p", count: MobileTerminalInputSendBuffer.maximumPendingByteCount + 1)

        #expect(buffer.enqueue(oversizedText, workspaceID: workspaceID, terminalID: terminalID) == .startDraining)
        #expect(buffer.pendingByteCount == oversizedText.utf8.count)

        let firstBatch = buffer.nextBatch()
        #expect(firstBatch?.text.utf8.count == MobileTerminalInputSendBuffer.maximumPendingByteCount)
        #expect(buffer.pendingByteCount == 1)
        #expect(buffer.enqueue("x", workspaceID: workspaceID, terminalID: terminalID) == .queued)

        let secondBatch = buffer.nextBatch()
        #expect(secondBatch?.text == "px")
        #expect(buffer.pendingByteCount == 0)
        #expect(buffer.nextBatch() == nil)
    }

    @Test func rejectsSingleInputAboveAbsoluteLimit() {
        var buffer = MobileTerminalInputSendBuffer()
        let workspaceID = MobileWorkspacePreview.ID(rawValue: "workspace-a")
        let terminalID = MobileTerminalPreview.ID(rawValue: "terminal-a")
        let tooLargeText = String(repeating: "p", count: MobileTerminalInputSendBuffer.maximumSingleInputByteCount + 1)

        #expect(buffer.enqueue(tooLargeText, workspaceID: workspaceID, terminalID: terminalID) == .rejected)
        #expect(buffer.pendingChunks.isEmpty)
        #expect(buffer.pendingByteCount == 0)
        #expect(buffer.nextBatch() == nil)
    }

    @Test func acceptsFollowOnInputWhileSingleOversizedInputDrains() {
        // Regression for the oversized-paste-then-keystroke gap: after a large
        // paste is accepted, `pendingByteCount` exceeds `maximumPendingByteCount`
        // until the drain loop's first `nextBatch()` splits it. A keystroke
        // arriving in that window (before the scheduled drain task runs) must be
        // queued, not rejected — a rejection would disconnect the session
        // (issue #6082 follow-on; see the enqueue overflow path).
        var buffer = MobileTerminalInputSendBuffer()
        let workspaceID = MobileWorkspacePreview.ID(rawValue: "workspace-a")
        let terminalID = MobileTerminalPreview.ID(rawValue: "terminal-a")
        let oversizedText = String(repeating: "p", count: MobileTerminalInputSendBuffer.maximumPendingByteCount + 1)

        #expect(buffer.enqueue(oversizedText, workspaceID: workspaceID, terminalID: terminalID) == .startDraining)
        #expect(buffer.pendingByteCount == oversizedText.utf8.count)
        #expect(buffer.pendingByteCount > MobileTerminalInputSendBuffer.maximumPendingByteCount)

        // The keystroke lands BEFORE any nextBatch() has run.
        #expect(buffer.enqueue("x", workspaceID: workspaceID, terminalID: terminalID) == .queued)
        #expect(buffer.pendingChunks.count == 1)
        #expect(buffer.pendingByteCount == oversizedText.utf8.count + 1)

        // It still drains in bounded batches, in order, with the keystroke last.
        let firstBatch = buffer.nextBatch()
        #expect(firstBatch?.text.utf8.count == MobileTerminalInputSendBuffer.maximumPendingByteCount)
        let secondBatch = buffer.nextBatch()
        #expect(secondBatch?.text == "px")
        #expect(buffer.pendingByteCount == 0)
        #expect(buffer.nextBatch() == nil)
    }

    @Test func rejectsFollowOnInputThatExceedsAbsoluteCeilingWhileOversizedDrains() {
        // The relaxed window is still bounded: once total pending would exceed
        // the absolute single-input ceiling, follow-on input is rejected.
        var buffer = MobileTerminalInputSendBuffer()
        let workspaceID = MobileWorkspacePreview.ID(rawValue: "workspace-a")
        let terminalID = MobileTerminalPreview.ID(rawValue: "terminal-a")
        let oversizedText = String(repeating: "p", count: MobileTerminalInputSendBuffer.maximumSingleInputByteCount)

        #expect(buffer.enqueue(oversizedText, workspaceID: workspaceID, terminalID: terminalID) == .startDraining)
        #expect(buffer.pendingByteCount == MobileTerminalInputSendBuffer.maximumSingleInputByteCount)
        #expect(buffer.enqueue("x", workspaceID: workspaceID, terminalID: terminalID) == .rejected)
        #expect(buffer.pendingByteCount == MobileTerminalInputSendBuffer.maximumSingleInputByteCount)
    }
}
