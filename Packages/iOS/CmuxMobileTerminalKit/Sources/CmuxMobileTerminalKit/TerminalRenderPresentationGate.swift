/// The kind of state transition represented by one render submission.
///
/// The renderer can receive output, a local scroll mutation, and a verified
/// replay request from different producers. They all have the same lifetime:
/// a request is not complete until its exact token reaches the presentation
/// layer.
public enum TerminalRenderSubmissionKind: Equatable, Sendable {
    case ordinary
    case localScroll
    case verifiedReplay
}

/// Metadata used to match an asynchronous presentation callback to its owner.
public struct TerminalRenderSubmission: Equatable, Sendable {
    public let token: UInt64
    public let generation: UInt64
    public let kind: TerminalRenderSubmissionKind
    /// Monotonic output mutation revision carried by this frame. A callback
    /// for an older frame must not reveal fallback content for newer output.
    public let outputRevision: UInt64

    public init(
        token: UInt64,
        generation: UInt64,
        kind: TerminalRenderSubmissionKind,
        outputRevision: UInt64 = 0
    ) {
        self.token = token
        self.generation = generation
        self.kind = kind
        self.outputRevision = outputRevision
    }

    public func carriesOutputRevision(_ revision: UInt64) -> Bool {
        outputRevision >= revision
    }
}

/// The action produced by a presentation-gate transition.
public enum TerminalRenderPresentationGateAction: Equatable, Sendable {
    case started(TerminalRenderSubmission)
    case queued(TerminalRenderSubmission)
    case ignored
    case idle
}

/// Serializes frame ownership at the surface boundary.
///
/// The gate deliberately stores only value metadata. The platform renderer
/// owns its surface and read-back payload, while this reducer owns the ordering
/// invariant and remains deterministic in unit tests.
public struct TerminalRenderPresentationGate: Sendable {
    public private(set) var inFlight: TerminalRenderSubmission?
    public private(set) var pending: TerminalRenderSubmission?
    public private(set) var isSuppressed = false

    public init() {}

    public mutating func enqueue(
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

    public mutating func complete(
        token: UInt64,
        generation: UInt64
    ) -> TerminalRenderPresentationGateAction {
        transitionAfterMatchingSubmission(
            token: token,
            generation: generation
        )
    }

    /// Drops a submission that could not reach the presentation layer.
    ///
    /// This is distinct from `complete`: an export or read-back failure can be
    /// known synchronously even though no presented callback will ever arrive.
    public mutating func cancel(
        token: UInt64,
        generation: UInt64
    ) -> TerminalRenderPresentationGateAction {
        transitionAfterMatchingSubmission(
            token: token,
            generation: generation
        )
    }

    public mutating func setSuppressed(
        _ suppressed: Bool
    ) -> TerminalRenderPresentationGateAction {
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

    public mutating func reset() {
        inFlight = nil
        pending = nil
        isSuppressed = false
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

    private mutating func queue(_ submission: TerminalRenderSubmission) {
        // A verified replay is the only submission that may supersede a
        // pending ordinary frame while presentation is frozen. Otherwise the
        // newest ordinary or local request represents the newest full model.
        if let pending,
           pending.kind == .verifiedReplay,
           submission.kind != .verifiedReplay {
            return
        }
        pending = submission
    }
}
