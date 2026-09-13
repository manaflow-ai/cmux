import CmuxTerminalCore
import Testing

@Suite struct TerminalPointerGestureStateTests {
    @Test func completionUsesPressModifiers() throws {
        var state = TerminalPointerGestureState()
        state.begin(windowNumber: 7, timestamp: 10, modifierFlagsRawValue: 0x0010_0000, permitsLinkActivation: true)
        let rawCompletion = state.complete(windowNumber: 7, timestamp: 11)
        let completion = try #require(rawCompletion)
        #expect(completion.modifierFlagsRawValue == 0x0010_0000)
        #expect(completion.permitsLinkActivation)
        #expect(!state.hasPendingRelease)
        let repeatedCompletion = state.complete(windowNumber: 7, timestamp: 12)
        #expect(repeatedCompletion == nil)
    }

    @Test func releaseFromAnotherWindowClearsAuthorization() {
        var state = TerminalPointerGestureState()
        state.begin(windowNumber: 7, timestamp: 10, modifierFlagsRawValue: 0, permitsLinkActivation: true)
        let completion = state.complete(windowNumber: 8, timestamp: 11)
        #expect(completion == nil)
        #expect(!state.hasPendingRelease)
    }

    @Test func staleReleaseClearsAuthorization() {
        var state = TerminalPointerGestureState()
        state.begin(windowNumber: 7, timestamp: 10, modifierFlagsRawValue: 0, permitsLinkActivation: true)
        let completion = state.complete(windowNumber: 7, timestamp: 9)
        #expect(completion == nil)
        #expect(!state.hasPendingRelease)
    }

    @Test func focusCancellationPreventsLaterActivation() {
        var state = TerminalPointerGestureState()
        state.begin(windowNumber: 7, timestamp: 10, modifierFlagsRawValue: 0, permitsLinkActivation: true)
        state.cancel()
        let completion = state.complete(windowNumber: 7, timestamp: 20)
        #expect(completion == nil)
    }

    @Test func pointerExitRetainsReleaseButRevokesActivation() throws {
        var state = TerminalPointerGestureState()
        state.begin(windowNumber: 7, timestamp: 10, modifierFlagsRawValue: 0, permitsLinkActivation: true)
        state.invalidateLinkActivation()
        #expect(state.hasPendingRelease)
        let rawCompletion = state.complete(windowNumber: 7, timestamp: 11)
        let completion = try #require(rawCompletion)
        #expect(!completion.permitsLinkActivation)
    }

    @Test func newerPressReplacesUnfinishedPress() throws {
        var state = TerminalPointerGestureState()
        state.begin(windowNumber: 7, timestamp: 10, modifierFlagsRawValue: 1, permitsLinkActivation: true)
        state.begin(windowNumber: 9, timestamp: 20, modifierFlagsRawValue: 2, permitsLinkActivation: false)
        let rawCompletion = state.complete(windowNumber: 9, timestamp: 21)
        let completion = try #require(rawCompletion)
        #expect(completion.modifierFlagsRawValue == 2)
        #expect(!completion.permitsLinkActivation)
    }
}
