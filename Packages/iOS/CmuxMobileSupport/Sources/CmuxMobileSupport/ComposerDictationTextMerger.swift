import Foundation

/// The dictation controller's state machine, factored out of the iOS-only
/// controller so the pure transitions are host-testable without the Speech /
/// AVFoundation frameworks.
///
/// Flow: `idle` -> `requestingPermission` (first tap, while authorization is
/// resolved) -> `listening` (engine running, partials streaming) -> `stopping`
/// (tearing down the engine/task) -> `idle`. A denied or unavailable recognizer
/// lands in `unavailable`, a terminal rest state that disables the mic button.
public enum ComposerDictationState: Equatable {
    /// Not listening; the mic button offers to start.
    case idle
    /// A tap was received and authorization is being resolved before the engine
    /// can start. Transient; the button shows the request is in flight.
    case requestingPermission
    /// The audio engine is running and partial transcriptions are streaming into
    /// the composer text.
    case listening
    /// Teardown is in progress (engine stopping, task cancelling). Transient.
    case stopping
    /// Speech recognition is unavailable on this device, or permission was denied
    /// or restricted. The mic button is disabled in this state.
    case unavailable

    /// Whether the engine is actively capturing audio (drives the listening UI).
    public var isListening: Bool { self == .listening }

    /// Whether dictation owns (or is about to own) the composer text and the field
    /// must be locked (non-editable). True while ``requestingPermission`` (the
    /// engine is spinning up off-main, ~100-300ms, after which partials will rewrite
    /// the field from the base text captured at start), ``listening`` (partials are
    /// streaming in), and ``stopping`` (the final result is still pending). Locking
    /// from the very first state guarantees a user edit cannot be silently discarded
    /// by a later partial/final callback: the user simply cannot type until dictation
    /// settles to ``idle``. (Locking through ``requestingPermission`` is what closes
    /// the async-spin-up edit-loss window the synchronous start path never had.) The
    /// mic toggle and send stay live, and send hard-cancels dictation back to
    /// ``idle``, re-enabling editing.
    public var locksComposerField: Bool {
        self == .requestingPermission || self == .listening || self == .stopping
    }

    /// Whether a tap should be accepted to start dictation. Rejected while a
    /// request is in flight, while already listening, while stopping, or when the
    /// recognizer is unavailable.
    public var canStart: Bool { self == .idle }

    /// Whether a tap should cancel a start whose authorization is still resolving.
    /// True only in ``requestingPermission``: a second tap there aborts the pending
    /// start and returns to idle so recognition never begins, rather than being
    /// ignored and letting the mic come on anyway when permission later resolves.
    public var canCancelPendingStart: Bool { self == .requestingPermission }

    /// Whether a graceful stop can finalize from this state. True only while
    /// ``listening``: a graceful stop flushes buffered audio and waits for the
    /// recognition task's final result. From any other state there is no live
    /// session to finalize, so the controller hard-cancels instead.
    public var canFinalize: Bool { self == .listening }

    /// Whether the controller is mid-teardown, waiting for the recognition task's
    /// final result before returning to idle. The mic is no longer capturing but
    /// the session has not fully settled. Distinguishes a graceful stop's transient
    /// wait from both the active ``listening`` state and the resting ``idle``.
    public var isStopping: Bool { self == .stopping }
}

/// Whether an asynchronous engine-ready callback still applies to the current
/// dictation start attempt, or has been superseded.
///
/// The audio engine now activates OFF the main actor (issue #6284), so its
/// "ready" callback lands ~100-300ms after the mic tap. In that window the user
/// can double-tap the mic, send, or navigate away — abandoning the start. Each
/// start stamps a monotonic token and every abandon bumps it, so the callback can
/// tell whether it is still the current attempt. Factored out as a pure value so
/// the supersession rule is host-testable without the Speech / AVFoundation stack.
///
/// `internal` (unlike the cross-module ``ComposerDictationState``): only the
/// in-module controller consumes it; tests reach it via `@testable import`.
enum ComposerDictationStartDisposition: Equatable {
    /// The engine came up for the CURRENT attempt: create the recognition task
    /// and move to ``ComposerDictationState/listening``.
    case apply
    /// A newer start, a cancel, or a teardown superseded this attempt: discard the
    /// result. The superseding path already enqueued the engine teardown (ordered
    /// before any later start on the owner's serial queue), so the callback must
    /// NOT enqueue another stop — doing so could race ahead and tear down a
    /// subsequent legitimate start.
    case discardStale
}

extension ComposerDictationState {
    /// Decide whether an engine-ready callback applies for this state (see
    /// ``ComposerDictationStartDisposition``).
    ///
    /// The callback applies only when its captured `callbackToken` still matches the
    /// controller's `currentToken` AND this state is still
    /// ``ComposerDictationState/requestingPermission`` (it has not already moved to
    /// ``ComposerDictationState/listening``, ``ComposerDictationState/idle``,
    /// ``ComposerDictationState/stopping``, or ``ComposerDictationState/unavailable``).
    /// The state check is belt-and-suspenders next to the token: any path that leaves
    /// `requestingPermission` while an engine start is in flight bumps the token too.
    ///
    /// - Parameters:
    ///   - callbackToken: The start token captured when this attempt kicked off the
    ///     off-main engine activation.
    ///   - currentToken: The controller's current start token at callback time.
    func startDisposition(callbackToken: Int, currentToken: Int) -> ComposerDictationStartDisposition {
        guard callbackToken == currentToken, self == .requestingPermission else {
            return .discardStale
        }
        return .apply
    }
}

/// Pure text merger for live dictation, factored out so it is host-testable
/// without Speech / AVFoundation.
///
/// At start the controller captures the composer's existing text as the
/// `base`. Every partial transcription then replaces the live tail, so the
/// composer always reads `base` + the latest transcript and never accumulates
/// stale partials. The base is preserved verbatim so text the user typed before
/// starting is never clobbered.
public struct ComposerDictationTextMerger: Sendable {
    /// Creates a stateless merger.
    public init() {}

    /// Combine the captured base text with the current transcript.
    ///
    /// - A trailing run of whitespace on the base is preserved (the user may
    ///   have typed "hello " and the dictation continues the sentence).
    /// - When the base ends in a non-whitespace character and the transcript is
    ///   non-empty, a single separating space is inserted so words do not run
    ///   together ("hello" + "world" -> "hello world").
    /// - An empty transcript yields the base unchanged (a partial may briefly be
    ///   empty); leading whitespace in the transcript is trimmed so the join is
    ///   not doubled.
    ///
    /// - Parameters:
    ///   - base: The composer text captured when dictation started.
    ///   - transcript: The latest (partial or final) recognized transcript.
    /// - Returns: The text to write back into the composer.
    public func merged(base: String, transcript: String) -> String {
        let trimmedTranscript = transcript.drop(while: { $0.isWhitespace })
        if trimmedTranscript.isEmpty {
            return base
        }
        if base.isEmpty {
            return String(trimmedTranscript)
        }
        if let last = base.last, last.isWhitespace {
            return base + trimmedTranscript
        }
        return base + " " + trimmedTranscript
    }
}
