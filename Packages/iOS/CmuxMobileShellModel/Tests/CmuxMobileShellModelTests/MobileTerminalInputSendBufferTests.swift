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

    @Test func splitsOversizedCoalescedInputAtUnicodeScalarBoundaries() {
        var buffer = MobileTerminalInputSendBuffer()
        let workspaceID = MobileWorkspacePreview.ID(rawValue: "workspace-a")
        let terminalID = MobileTerminalPreview.ID(rawValue: "terminal-a")
        let text = "abcéé漢漢z"

        #expect(buffer.enqueue("abc", workspaceID: workspaceID, terminalID: terminalID) == .startDraining)
        #expect(buffer.enqueue("éé漢漢z", workspaceID: workspaceID, terminalID: terminalID) == .queued)
        #expect(buffer.pendingByteCount == text.utf8.count)

        let first = buffer.nextBatch(maximumByteCount: 4)
        #expect(first?.text == "abc")
        #expect(buffer.pendingByteCount == "éé漢漢z".utf8.count)
        let second = buffer.nextBatch(maximumByteCount: 4)
        #expect(second?.text == "éé")
        #expect(buffer.pendingByteCount == "漢漢z".utf8.count)
        let third = buffer.nextBatch(maximumByteCount: 4)
        #expect(third?.text == "漢")
        #expect(buffer.pendingByteCount == "漢z".utf8.count)
        let fourth = buffer.nextBatch(maximumByteCount: 4)
        #expect(fourth?.text == "漢z")
        #expect(buffer.pendingByteCount == 0)
        #expect([first?.text, second?.text, third?.text, fourth?.text].compactMap { $0 }.joined() == text)
        #expect(buffer.nextBatch(maximumByteCount: 4) == nil)
    }

    @Test func emitsWholeScalarWhenCapIsNarrowerThanFirstScalar() {
        var buffer = MobileTerminalInputSendBuffer()
        let workspaceID = MobileWorkspacePreview.ID(rawValue: "workspace-a")
        let terminalID = MobileTerminalPreview.ID(rawValue: "terminal-a")

        #expect(buffer.enqueue("漢z", workspaceID: workspaceID, terminalID: terminalID) == .startDraining)
        // "漢" is 3 UTF-8 bytes; a 1-byte cap cannot split at a scalar boundary,
        // so the drain must still make progress by emitting the scalar whole.
        #expect(buffer.nextBatch(maximumByteCount: 1)?.text == "漢")
        #expect(buffer.nextBatch(maximumByteCount: 1)?.text == "z")
        #expect(buffer.pendingByteCount == 0)
        #expect(buffer.nextBatch(maximumByteCount: 1) == nil)
    }

    @Test func passesThroughExactCapAndSmallChunks() {
        var buffer = MobileTerminalInputSendBuffer()
        let workspaceID = MobileWorkspacePreview.ID(rawValue: "workspace-a")
        let terminalID = MobileTerminalPreview.ID(rawValue: "terminal-a")

        #expect(buffer.enqueue("éé", workspaceID: workspaceID, terminalID: terminalID) == .startDraining)
        #expect(buffer.nextBatch(maximumByteCount: 4)?.text == "éé")
        #expect(buffer.pendingByteCount == 0)
        #expect(buffer.enqueue("漢", workspaceID: workspaceID, terminalID: terminalID) == .queued)
        #expect(buffer.nextBatch(maximumByteCount: 4)?.text == "漢")
        #expect(buffer.pendingByteCount == 0)
        #expect(buffer.nextBatch(maximumByteCount: 4) == nil)
    }
}
