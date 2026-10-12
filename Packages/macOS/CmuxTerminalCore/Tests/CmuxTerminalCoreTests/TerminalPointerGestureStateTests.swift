import CmuxTerminalCore
import Testing

@Suite struct TerminalPointerGestureStateTests {
    @Test func completionUsesPressModifiers() throws {
        var state = TerminalPointerGestureState()
        state.begin(windowNumber: 7, timestamp: 10, modifierFlagsRawValue: 0x0010_0000, permitsLinkActivation: true, pressPointX: 10, pressPointY: 20)
        let rawCompletion = state.complete(windowNumber: 7, timestamp: 11)
        let completion = try #require(rawCompletion)
        #expect(completion.modifierFlagsRawValue == 0x0010_0000)
        #expect(completion.permitsLinkActivation)
        #expect(!completion.isDrag)
        #expect(!state.hasPendingRelease)
        let repeatedCompletion = state.complete(windowNumber: 7, timestamp: 12)
        #expect(repeatedCompletion == nil)
    }

    @Test func releaseFromAnotherWindowClearsAuthorization() {
        var state = TerminalPointerGestureState()
        state.begin(windowNumber: 7, timestamp: 10, modifierFlagsRawValue: 0, permitsLinkActivation: true, pressPointX: 10, pressPointY: 20)
        let completion = state.complete(windowNumber: 8, timestamp: 11)
        #expect(completion == nil)
        #expect(!state.hasPendingRelease)
    }

    @Test func staleReleaseClearsAuthorization() {
        var state = TerminalPointerGestureState()
        state.begin(windowNumber: 7, timestamp: 10, modifierFlagsRawValue: 0, permitsLinkActivation: true, pressPointX: 10, pressPointY: 20)
        let completion = state.complete(windowNumber: 7, timestamp: 9)
        #expect(completion == nil)
        #expect(!state.hasPendingRelease)
    }

    @Test func focusCancellationPreventsLaterActivation() {
        var state = TerminalPointerGestureState()
        state.begin(windowNumber: 7, timestamp: 10, modifierFlagsRawValue: 0, permitsLinkActivation: true, pressPointX: 10, pressPointY: 20)
        state.cancel()
        let completion = state.complete(windowNumber: 7, timestamp: 20)
        #expect(completion == nil)
    }

    @Test func pointerExitRetainsReleaseButRevokesActivation() throws {
        var state = TerminalPointerGestureState()
        state.begin(windowNumber: 7, timestamp: 10, modifierFlagsRawValue: 0, permitsLinkActivation: true, pressPointX: 10, pressPointY: 20)
        state.invalidateLinkActivation()
        #expect(state.hasPendingRelease)
        let rawCompletion = state.complete(windowNumber: 7, timestamp: 11)
        let completion = try #require(rawCompletion)
        #expect(!completion.permitsLinkActivation)
    }

    @Test func dragCompletionRecordsSelectionGesture() throws {
        var state = TerminalPointerGestureState()
        state.begin(windowNumber: 7, timestamp: 10, modifierFlagsRawValue: 0, permitsLinkActivation: false, pressPointX: 10, pressPointY: 20)
        state.markDragged(atX: 11, y: 21)
        #expect(!state.isDrag)
        state.markDragged(atX: 14, y: 20)
        #expect(state.isDrag)
        let rawCompletion = state.complete(windowNumber: 7, timestamp: 11)
        let completion = try #require(rawCompletion)
        #expect(completion.isDrag)
        #expect(!state.isDrag)
    }

    @Test func clipboardWriteCountKeepsTripleClickWritesTogether() {
        #expect(TerminalPointerGestureState.clipboardWriteCount(isDrag: true, clickCount: 1) == 1)
        #expect(TerminalPointerGestureState.clipboardWriteCount(isDrag: true, clickCount: 3) == 2)
        #expect(TerminalPointerGestureState.clipboardWriteCount(isDrag: false, clickCount: 1) == 0)
        #expect(TerminalPointerGestureState.clipboardWriteCount(isDrag: false, clickCount: 2) == 1)
        #expect(TerminalPointerGestureState.clipboardWriteCount(isDrag: false, clickCount: 3) == 2)
        #expect(TerminalPointerGestureState.clipboardWriteCount(isDrag: false, clickCount: 99) == 3)
    }

    @Test func shiftClickCompletesOneCopySelection() {
        #expect(TerminalPointerGestureState.clipboardWriteCount(
            isDrag: false,
            clickCount: 1,
            isShiftClick: true
        ) == 1)
        #expect(TerminalPointerGestureState.clipboardWriteCount(
            isDrag: false,
            clickCount: 1,
            isShiftClick: false
        ) == 0)
    }

    @Test func newerPressReplacesUnfinishedPress() throws {
        var state = TerminalPointerGestureState()
        state.begin(windowNumber: 7, timestamp: 10, modifierFlagsRawValue: 1, permitsLinkActivation: true, pressPointX: 10, pressPointY: 20)
        state.begin(windowNumber: 9, timestamp: 20, modifierFlagsRawValue: 2, permitsLinkActivation: false, pressPointX: 30, pressPointY: 40)
        let rawCompletion = state.complete(windowNumber: 9, timestamp: 21)
        let completion = try #require(rawCompletion)
        #expect(completion.modifierFlagsRawValue == 2)
        #expect(!completion.permitsLinkActivation)
    }
}
