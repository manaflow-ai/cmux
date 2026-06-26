import Testing
@testable import CmuxMobileSupport

/// Host-testable coverage for the dictation text-merge and the state machine's
/// pure transitions. The Speech / AVFoundation engine wiring is iOS-only and not
/// host-compilable, so it is exercised only on device / simulator.
@Suite struct ComposerDictationTests {
    private let textMerger = ComposerDictationTextMerger()

    // MARK: - Text merge

    @Test func mergeAppendsTranscriptToEmptyBase() {
        #expect(textMerger.merged(base: "", transcript: "hello world") == "hello world")
    }

    @Test func mergeInsertsSeparatingSpaceAfterNonWhitespaceBase() {
        #expect(textMerger.merged(base: "hello", transcript: "world") == "hello world")
    }

    @Test func mergePreservesTrailingWhitespaceWithoutDoubling() {
        // Base already ends in a space; do not add a second one.
        #expect(textMerger.merged(base: "hello ", transcript: "world") == "hello world")
    }

    @Test func mergeTrimsLeadingTranscriptWhitespace() {
        #expect(textMerger.merged(base: "hello", transcript: "   world") == "hello world")
    }

    @Test func mergeEmptyTranscriptKeepsBaseUnchanged() {
        // A partial may briefly be empty; the user's pre-typed text must survive.
        #expect(textMerger.merged(base: "draft ", transcript: "") == "draft ")
        #expect(textMerger.merged(base: "draft", transcript: "   ") == "draft")
    }

    @Test func mergePreservesBaseVerbatim() {
        // The base is appended to, never rewritten: punctuation and casing stay.
        let base = "TODO: ship it,"
        #expect(textMerger.merged(base: base, transcript: "then rest") == "TODO: ship it, then rest")
    }

    @Test func mergeIsIdempotentAcrossGrowingPartials() {
        // Successive partials always replace the tail, so the base is never
        // duplicated as the transcript grows.
        let base = "note: "
        #expect(textMerger.merged(base: base, transcript: "buy") == "note: buy")
        #expect(textMerger.merged(base: base, transcript: "buy milk") == "note: buy milk")
        #expect(textMerger.merged(base: base, transcript: "buy milk today") == "note: buy milk today")
    }

    @Test func mergeEmptyBaseEmptyTranscriptIsEmpty() {
        #expect(textMerger.merged(base: "", transcript: "") == "")
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

    // MARK: - Graceful stop vs hard cancel

    @Test func onlyListeningCanFinalizeGracefully() {
        // A graceful stop finalizes only a live session; from any other state the
        // controller hard-cancels instead, so there is no live task to await.
        #expect(ComposerDictationState.listening.canFinalize)
        #expect(!ComposerDictationState.idle.canFinalize)
        #expect(!ComposerDictationState.requestingPermission.canFinalize)
        #expect(!ComposerDictationState.stopping.canFinalize)
        #expect(!ComposerDictationState.unavailable.canFinalize)
    }

    @Test func stoppingIsTheOnlyFinalizingWaitState() {
        // `.stopping` marks the transient wait for the final result; it is neither
        // capturing (`isListening`) nor accepting a new start (`canStart`).
        #expect(ComposerDictationState.stopping.isStopping)
        #expect(!ComposerDictationState.stopping.isListening)
        #expect(!ComposerDictationState.stopping.canStart)
        for state in [
            ComposerDictationState.idle,
            .requestingPermission,
            .listening,
            .unavailable,
        ] {
            #expect(!state.isStopping)
        }
    }

    @Test func finalizeAndStartAreMutuallyExclusivePerState() {
        // A state is never both ready to start a fresh session and ready to
        // finalize a live one, so the graceful-stop and start paths never collide.
        for state in [
            ComposerDictationState.idle,
            .requestingPermission,
            .listening,
            .stopping,
            .unavailable,
        ] {
            #expect(!(state.canStart && state.canFinalize))
        }
    }

    // MARK: - Field lock (dictation owns the text)

    @Test func dictationLocksFieldWhileListeningAndStopping() {
        // While dictation owns the composer text the field must be locked so a
        // user edit cannot be silently clobbered by the next partial/final
        // callback. Both the live capture and the finalize-wait own the text.
        #expect(ComposerDictationState.listening.locksComposerField)
        #expect(ComposerDictationState.stopping.locksComposerField)
    }

    @Test func dictationLeavesFieldEditableWhenNotActive() {
        // Idle (no session), requestingPermission (engine not started, the field
        // still holds only what the user typed), and unavailable all leave the
        // field editable: no callback will overwrite the user's text.
        #expect(!ComposerDictationState.idle.locksComposerField)
        #expect(!ComposerDictationState.requestingPermission.locksComposerField)
        #expect(!ComposerDictationState.unavailable.locksComposerField)
    }

    @Test func fieldLockMatchesEngineOwnership() {
        // The lock holds for exactly the states where a recognition callback can
        // rewrite the field (listening streams partials, stopping awaits the
        // final), and for no other state.
        for state in [
            ComposerDictationState.idle,
            .requestingPermission,
            .listening,
            .stopping,
            .unavailable,
        ] {
            let ownsText = state == .listening || state == .stopping
            #expect(state.locksComposerField == ownsText)
        }
    }

    @Test func canStartImpliesFieldUnlocked() {
        // A startable state is never a locked state: the user can always edit a
        // field from which dictation can be (re)started, and dictation only locks
        // once it actually owns the text.
        for state in [
            ComposerDictationState.idle,
            .requestingPermission,
            .listening,
            .stopping,
            .unavailable,
        ] {
            if state.canStart {
                #expect(!state.locksComposerField)
            }
        }
    }

    @Test func gracefulStopFinalizesOnlyFromListening() {
        // Mirrors the controller's `stop()` branch: a graceful stop finalizes from
        // `.listening` and otherwise falls back to a hard cancel (which finalizes
        // from no state). The two paths partition the states with no overlap.
        for state in [
            ComposerDictationState.idle,
            .requestingPermission,
            .listening,
            .stopping,
            .unavailable,
        ] {
            let takesGracefulPath = state.canFinalize
            #expect(takesGracefulPath == (state == .listening))
        }
    }
}
