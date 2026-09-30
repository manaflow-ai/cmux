import Foundation

/// Decides whether an agent turn that ended in an error should be resumed
/// automatically, and when.
///
/// A capacity blip (model at capacity, overloaded, a dropped connection) can
/// end an autonomous agent's turn even after CodeRouter has held and retried
/// the request. The agent then sits idle until a human types "continue". The
/// tracker turns journaled lifecycle events into resume decisions: it
/// schedules a resume only for a turn that ended on a retryable failure,
/// backs off between attempts, and cancels as soon as anything shows the
/// agent is working again or waiting on a human.
public struct AgentAutoResumeTracker: Sendable, Equatable {
    /// What the caller should do after observing an event.
    public enum Action: Sendable, Equatable {
        /// Nothing changes.
        case none
        /// Send `continue` to the surface after `delay`, unless cancelled.
        /// `token` identifies this schedule; a stale timer must not fire.
        case schedule(surfaceId: String, attempt: Int, delay: Duration, token: UInt64)
        /// Drop any pending resume for the surface.
        case cancel(surfaceId: String)
    }

    /// Waits before each consecutive resume of one failing streak. The
    /// first resume lands within about a minute; the streak stops after the
    /// last delay so a persistent outage does not loop forever.
    public static let defaultDelays: [Duration] = [.seconds(20), .seconds(45), .seconds(90), .seconds(180), .seconds(300)]

    private struct SurfaceState: Sendable, Equatable {
        /// Native agent session currently owning the surface.
        var sessionId: String?
        /// Resumes sent in the current failing streak.
        var streak = 0
        /// Resumes sent since the agent session started, for the marker.
        var total = 0
        /// Token of the pending schedule, if any.
        var pendingToken: UInt64?
    }

    public let delays: [Duration]
    private let classifier = AgentRetryableFailureClassifier()
    private var surfaces: [String: SurfaceState] = [:]
    private var nextToken: UInt64 = 0

    public init(delays: [Duration] = AgentAutoResumeTracker.defaultDelays) {
        self.delays = delays
    }

    /// Resumes sent for the surface since its agent session started.
    public func totalResumes(surfaceId: String) -> Int {
        surfaces[surfaceId]?.total ?? 0
    }

    /// True while `token` is still the surface's pending schedule.
    public func isPending(surfaceId: String, token: UInt64) -> Bool {
        surfaces[surfaceId]?.pendingToken == token
    }

    /// Returns the native session identity captured by a pending schedule.
    public func pendingSessionId(surfaceId: String, token: UInt64) -> String? {
        guard surfaces[surfaceId]?.pendingToken == token else { return nil }
        return surfaces[surfaceId]?.sessionId
    }

    /// Folds one journaled event for a surface into a decision.
    public mutating func observe(
        kind: AgentJournalEventKind,
        surfaceId: String,
        isSubagent: Bool,
        detail: String?,
        sessionId: String? = nil
    ) -> Action {
        // Nested agents report through their parent; resuming the parent
        // pane for a child's failure would inject text into the wrong turn.
        guard !isSubagent else { return .none }
        switch kind {
        case .errorReported:
            if let sessionId, !sessionId.isEmpty {
                if let currentSessionId = surfaces[surfaceId]?.sessionId,
                   !currentSessionId.isEmpty,
                   currentSessionId != sessionId {
                    // A late error from an older session must not replace the
                    // session that a newer sessionStarted event established.
                    return .none
                }
                if surfaces[surfaceId]?.sessionId != sessionId {
                    surfaces[surfaceId] = SurfaceState(sessionId: sessionId)
                }
            }
            // The same failure can arrive twice: once with its detail and
            // once through the error notification without one. An event with
            // no detail says nothing new, so it neither schedules nor cancels.
            guard let detail, !detail.isEmpty else { return .none }
            var state = surfaces[surfaceId] ?? SurfaceState()
            guard classifier.isRetryable(detail: detail), state.streak < delays.count else {
                let hadPending = state.pendingToken != nil
                state.pendingToken = nil
                surfaces[surfaceId] = state
                return hadPending ? .cancel(surfaceId: surfaceId) : .none
            }
            nextToken &+= 1
            state.pendingToken = nextToken
            let delay = delays[state.streak]
            surfaces[surfaceId] = state
            return .schedule(surfaceId: surfaceId, attempt: state.streak + 1, delay: delay, token: nextToken)
        case .turnCompleted:
            guard !isStaleLifecycleEvent(surfaceId: surfaceId, sessionId: sessionId) else { return .none }
            // A turn finished normally: the failing streak is over. The total
            // stays so the marker still shows the turn needed help.
            guard var state = surfaces[surfaceId] else { return .none }
            let hadPending = state.pendingToken != nil
            state.streak = 0
            state.pendingToken = nil
            surfaces[surfaceId] = state
            return hadPending ? .cancel(surfaceId: surfaceId) : .none
        case .turnStarted, .approvalRequested, .questionRequested, .planReviewRequested, .attentionResolved:
            guard !isStaleLifecycleEvent(surfaceId: surfaceId, sessionId: sessionId) else { return .none }
            // The agent is working again, or waits on a human: never type
            // into it on a timer.
            return cancelPending(surfaceId: surfaceId)
        case .sessionEnded:
            guard !isStaleLifecycleEvent(surfaceId: surfaceId, sessionId: sessionId) else { return .none }
            let hadPending = surfaces[surfaceId]?.pendingToken != nil
            surfaces[surfaceId] = nil
            return hadPending ? .cancel(surfaceId: surfaceId) : .none
        case .sessionStarted:
            let hadPending = surfaces[surfaceId]?.pendingToken != nil
            surfaces[surfaceId] = SurfaceState(sessionId: sessionId)
            return hadPending ? .cancel(surfaceId: surfaceId) : .none
        case .childSpawned, .childCompleted, .childFailed, .stateChanged,
             .idleObserved, .messagePublished:
            // Progress and idle observations do not change whether the
            // errored turn still needs a resume. An idle prompt that follows
            // an error is exactly the state a resume addresses.
            return .none
        }
    }

    /// Records that the scheduled resume for `token` was sent. Returns the
    /// surface's new total, or `nil` when the schedule was already cancelled.
    public mutating func resumeSent(surfaceId: String, token: UInt64) -> Int? {
        guard var state = surfaces[surfaceId], state.pendingToken == token else { return nil }
        state.pendingToken = nil
        state.streak += 1
        state.total += 1
        surfaces[surfaceId] = state
        return state.total
    }

    /// Forgets a pending schedule that could not be delivered.
    public mutating func abandon(surfaceId: String, token: UInt64) {
        guard surfaces[surfaceId]?.pendingToken == token else { return }
        surfaces[surfaceId]?.pendingToken = nil
    }

    /// Cancels and forgets a pending resume after explicit user input.
    public mutating func explicitInput(surfaceId: String) -> Action {
        guard var state = surfaces[surfaceId] else { return .none }
        let hadPending = state.pendingToken != nil
        state.streak = 0
        state.pendingToken = nil
        surfaces[surfaceId] = state
        return hadPending ? .cancel(surfaceId: surfaceId) : .none
    }

    private mutating func cancelPending(surfaceId: String) -> Action {
        guard surfaces[surfaceId]?.pendingToken != nil else { return .none }
        surfaces[surfaceId]?.pendingToken = nil
        return .cancel(surfaceId: surfaceId)
    }

    private func isStaleLifecycleEvent(surfaceId: String, sessionId: String?) -> Bool {
        guard let sessionId, !sessionId.isEmpty,
              let currentSessionId = surfaces[surfaceId]?.sessionId,
              !currentSessionId.isEmpty else { return false }
        return currentSessionId != sessionId
    }
}

/// Classifies an agent's reported turn failure as retryable (an upstream
/// capacity or transport problem that clears on its own) or not.
public struct AgentRetryableFailureClassifier: Sendable, Equatable {
    public init() {}

    /// Failures a retry cannot fix: credentials, billing, quota, and
    /// request errors. Checked first so "rate limit" wording inside a quota
    /// message does not count as transient.
    static let permanentMarkers = [
        "authentication", "authentication_failed", "unauthorized", "invalid api key", "invalid_api_key",
        "oauth_org_not_allowed", "account_on_hold", "billing", "cloud_credential",
        "invalid_request", "model_not_found", "max_output_tokens", "prompt is too long", "context length",
        "context_length", "usage limit", "usage_limit", "quota", "insufficient",
        "permission denied",
    ]

    /// Upstream capacity and transport failures.
    static let retryableMarkers = [
        "overloaded", "at capacity", "model_capacity", "server_overloaded", "server_error", "server error",
        "rate_limit", "rate limit", "rate-limit", "too many requests",
        "stream disconnected", "stream_error", "stream error", "connection", "econnreset", "econnrefused",
        "etimedout", "timed out", "timeout", "network", "socket hang up", "temporarily unavailable",
        "service unavailable", "bad gateway", "internal server error", "try again",
    ]

    public func isRetryable(detail: String?) -> Bool {
        guard let detail, !detail.isEmpty else { return false }
        let text = detail.lowercased()
        if Self.permanentMarkers.contains(where: text.contains) { return false }
        return Self.retryableMarkers.contains(where: text.contains) || containsRetryableStatus(text)
    }

    /// HTTP statuses that mean "try again", matched as whole numbers so a
    /// token count such as `15000` never reads as a 500.
    func containsRetryableStatus(_ text: String) -> Bool {
        var digits = ""
        for character in text + " " {
            if character.isASCII, character.isNumber {
                digits.append(character)
                continue
            }
            if ["429", "500", "502", "503", "504", "529"].contains(digits) { return true }
            digits = ""
        }
        return false
    }
}
