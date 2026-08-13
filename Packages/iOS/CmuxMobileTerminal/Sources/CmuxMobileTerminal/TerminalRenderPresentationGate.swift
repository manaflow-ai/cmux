import Foundation

/// The kind of state transition represented by one render submission.
///
/// The renderer can receive output, a local scroll mutation, and a verified
/// replay request from different producers. They all have the same lifetime:
/// a request is not complete until its exact token reaches the presentation
/// layer.
enum TerminalRenderSubmissionKind: Equatable, Sendable {
    case ordinary
    case localScroll
    case verifiedReplay
}

/// Metadata used to match an asynchronous presentation callback to its owner.
struct TerminalRenderSubmission: Equatable, Sendable {
    let token: UInt64
    let generation: UInt64
    let kind: TerminalRenderSubmissionKind
}

/// The action produced by a presentation-gate transition.
enum TerminalRenderPresentationGateAction: Equatable {
    case started(TerminalRenderSubmission)
    case queued(TerminalRenderSubmission)
    case ignored
    case idle
}

/// Serializes frame ownership at the surface boundary.
///
/// The gate deliberately stores only value metadata. `GhosttySurfaceView`
/// owns the associated C surface and read-back payload, while this reducer
/// owns the ordering invariant and remains deterministic in unit tests.
struct TerminalRenderPresentationGate: Sendable {
    private(set) var inFlight: TerminalRenderSubmission?
    private(set) var pending: TerminalRenderSubmission?
    private(set) var isSuppressed = false

    mutating func enqueue(
        _ submission: TerminalRenderSubmission
    ) -> TerminalRenderPresentationGateAction {
        if isSuppressed, submission.kind != .verifiedReplay {
            queue(submission)
            return .queued(submission)
        }
        guard inFlight == nil else {
            queue(submission)
            return .queued(submission)
        }
        inFlight = submission
        return .started(submission)
    }

    mutating func complete(
        token: UInt64,
        generation: UInt64
    ) -> TerminalRenderPresentationGateAction {
        transitionAfterMatchingSubmission(
            token: token,
            generation: generation
        )
    }

    /// Drops a submission that could not reach Ghostty's presentation layer.
    ///
    /// This is distinct from `complete`: an export/readback failure can be
    /// known synchronously even though no render-presented callback will ever
    /// arrive. Keeping that failed token in flight would block every later
    /// output and scroll frame until the watchdog tears down the surface.
    mutating func cancel(
        token: UInt64,
        generation: UInt64
    ) -> TerminalRenderPresentationGateAction {
        transitionAfterMatchingSubmission(
            token: token,
            generation: generation
        )
    }

    private mutating func transitionAfterMatchingSubmission(
        token: UInt64,
        generation: UInt64
    ) -> TerminalRenderPresentationGateAction {
        guard let current = inFlight,
              current.token == token,
              current.generation == generation else {
            return .ignored
        }
        inFlight = nil
        guard let pending,
              !isSuppressed || pending.kind == .verifiedReplay else {
            return .idle
        }
        self.pending = nil
        inFlight = pending
        return .started(pending)
    }

    mutating func setSuppressed(_ suppressed: Bool) -> TerminalRenderPresentationGateAction {
        isSuppressed = suppressed
        guard !suppressed,
              inFlight == nil,
              let pending else {
            return .idle
        }
        self.pending = nil
        inFlight = pending
        return .started(pending)
    }

    mutating func reset() {
        inFlight = nil
        pending = nil
        isSuppressed = false
    }

    private mutating func queue(_ submission: TerminalRenderSubmission) {
        // A verified replay is the only submission that may supersede a
        // pending ordinary frame while presentation is frozen. Otherwise the
        // newest ordinary/local request represents the newest complete model.
        if let pending,
           pending.kind == .verifiedReplay,
           submission.kind != .verifiedReplay {
            return
        }
        pending = submission
    }
}
