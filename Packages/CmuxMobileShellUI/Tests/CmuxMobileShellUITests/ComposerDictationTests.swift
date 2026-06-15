import Testing
@testable import CmuxMobileShellUI

/// Host-testable coverage for the dictation text-merge and the state machine's
/// pure transitions. The Speech / AVFoundation engine wiring is iOS-only and not
/// host-compilable, so it is exercised only on device / simulator.
@Suite struct ComposerDictationTests {
    // MARK: - Text merge

    @Test func mergeAppendsTranscriptToEmptyBase() {
        #expect(ComposerDictationTextMerge.merged(base: "", transcript: "hello world") == "hello world")
    }

    @Test func mergeInsertsSeparatingSpaceAfterNonWhitespaceBase() {
        #expect(ComposerDictationTextMerge.merged(base: "hello", transcript: "world") == "hello world")
    }

    @Test func mergePreservesTrailingWhitespaceWithoutDoubling() {
        // Base already ends in a space; do not add a second one.
        #expect(ComposerDictationTextMerge.merged(base: "hello ", transcript: "world") == "hello world")
    }

    @Test func mergeTrimsLeadingTranscriptWhitespace() {
        #expect(ComposerDictationTextMerge.merged(base: "hello", transcript: "   world") == "hello world")
    }

    @Test func mergeEmptyTranscriptKeepsBaseUnchanged() {
        // A partial may briefly be empty; the user's pre-typed text must survive.
        #expect(ComposerDictationTextMerge.merged(base: "draft ", transcript: "") == "draft ")
        #expect(ComposerDictationTextMerge.merged(base: "draft", transcript: "   ") == "draft")
    }

    @Test func mergePreservesBaseVerbatim() {
        // The base is appended to, never rewritten: punctuation and casing stay.
        let base = "TODO: ship it,"
        #expect(ComposerDictationTextMerge.merged(base: base, transcript: "then rest") == "TODO: ship it, then rest")
    }

    @Test func mergeIsIdempotentAcrossGrowingPartials() {
        // Successive partials always replace the tail, so the base is never
        // duplicated as the transcript grows.
        let base = "note: "
        #expect(ComposerDictationTextMerge.merged(base: base, transcript: "buy") == "note: buy")
        #expect(ComposerDictationTextMerge.merged(base: base, transcript: "buy milk") == "note: buy milk")
        #expect(ComposerDictationTextMerge.merged(base: base, transcript: "buy milk today") == "note: buy milk today")
    }

    @Test func mergeEmptyBaseEmptyTranscriptIsEmpty() {
        #expect(ComposerDictationTextMerge.merged(base: "", transcript: "") == "")
    }

    // MARK: - State machine

    @Test func idleCanStartAndIsNotListening() {
        let state = ComposerDictationState.idle
        #expect(state.canStart)
        #expect(!state.isListening)
    }

    @Test func listeningIsListeningButCannotStart() {
        let state = ComposerDictationState.listening
        #expect(state.isListening)
        #expect(!state.canStart)
    }

    @Test func transientStatesRejectStart() {
        #expect(!ComposerDictationState.requestingPermission.canStart)
        #expect(!ComposerDictationState.stopping.canStart)
    }

    @Test func unavailableRejectsStartAndIsNotListening() {
        let state = ComposerDictationState.unavailable
        #expect(!state.canStart)
        #expect(!state.isListening)
    }

    @Test func onlyRequestingPermissionCanCancelPendingStart() {
        // A second tap while authorization is resolving cancels the pending start;
        // every other state ignores cancellation (it has nothing to abort).
        #expect(ComposerDictationState.requestingPermission.canCancelPendingStart)
        #expect(!ComposerDictationState.idle.canCancelPendingStart)
        #expect(!ComposerDictationState.listening.canCancelPendingStart)
        #expect(!ComposerDictationState.stopping.canCancelPendingStart)
        #expect(!ComposerDictationState.unavailable.canCancelPendingStart)
    }

    @Test func cancelAndStartAreMutuallyExclusivePerState() {
        // A tap resolves to exactly one of start / cancel / neither, never both, so
        // toggle's branching is unambiguous in every state.
        for state in [
            ComposerDictationState.idle,
            .requestingPermission,
            .listening,
            .stopping,
            .unavailable,
        ] {
            #expect(!(state.canStart && state.canCancelPendingStart))
        }
    }
}
