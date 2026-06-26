import CMUXAgentLaunch
import CmuxControlSocket
import CmuxFeedback
import Foundation

/// App-side wiring for the worker-lane feed/feedback control commands
/// (`feed.push`, `feed.permission.reply`, `feed.question.reply`,
/// `feed.exit_plan.reply`, `feedback.submit`).
///
/// The command bodies live in CmuxControlSocket's ``ControlFeedWorker``; this
/// file supplies the live-state seam (``ControlFeedWorkerReading``) the worker
/// reaches through, plus the synchronous worker-lane entry point that drives it.
///
/// ## Why the seam, not a direct call
///
/// `ControlFeedWorker` is in a package that must not import the app target's
/// feed plumbing (`CmuxEventBus`, `FeedCoordinator`, `FeedSocketEncoding`, the
/// `WorkstreamEvent` decode, the iMessage-mode side effects, the feedback
/// composer). ``ControlFeedWorkerReading`` inverts that: the package owns the
/// protocol and the typed outcomes; ``TerminalControllerFeedWorkerReading``
/// conforms it over a `weak` `TerminalController`, forwarding to the controller's
/// co-located `controlFeed*` resolvers. Those resolvers run on the calling
/// socket-worker thread and block exactly where the legacy `nonisolated`
/// `v2FeedPush` / `v2FeedbackSubmit` bodies did (`FeedCoordinator.ingestBlocking`,
/// the feedback `DispatchSemaphore`), hopping to main only inside their existing
/// `v2MainSync` / `Task { @MainActor }` blocks.
extension TerminalController {
    /// Drives the package ``ControlFeedWorker`` for one decoded feed/feedback
    /// request from the synchronous socket-worker lane. The worker is synchronous
    /// (it blocks the worker thread like the legacy bodies), so no
    /// worker-thread→async bridge is needed here. The worker only ever returns
    /// `nil` for non-feed/feedback methods, which the dispatcher never routes
    /// here, so a `nil` result reports the same encode-failure response the legacy
    /// `v2Ok`/`v2Error` plumbing produced for an impossible payload.
    nonisolated func runFeedWorker(_ request: ControlRequest) -> String {
        guard let worker = controlFeedWorker,
              let result = worker.handle(request) else {
            return ControlResponseEncoder.encodeFailureResponse
        }
        return Self.v2Encoder.response(id: request.id, result)
    }

    /// Decodes, publishes, applies side effects for, and blocking-ingests a
    /// `feed.push` event (the app-coupled core of the legacy `v2FeedPush` body,
    /// after the worker performed the wait-timeout parse and event-presence
    /// checks). Returns the `IngestBlockingResult.socketEncodedDictionary` bridged
    /// to ``JSONValue``, or `.decodeFailed` so the worker builds the byte-identical
    /// decode-error message.
    nonisolated func controlFeedPushEvent(
        eventPayload: [String: JSONValue],
        waitTimeoutSeconds: TimeInterval
    ) -> ControlFeedPushOutcome {
        let eventDict = eventPayload.mapValues(\.foundationObject)
        let event: WorkstreamEvent
        do {
            let data = try JSONSerialization.data(withJSONObject: eventDict)
            event = try JSONDecoder().decode(WorkstreamEvent.self, from: data)
        } catch {
            return .decodeFailed(errorDescription: "\(error)")
        }

        CmuxEventBus.shared.publishWorkstreamEvent(event, phase: "received")
        v2ApplyIMessageModeSideEffects(for: event)
        Task { @MainActor in self.agentChatTranscriptService?.noteHookEvent(event) }

        let result = FeedCoordinator.shared.ingestBlocking(
            event: event,
            waitTimeout: waitTimeoutSeconds
        )
        CmuxEventBus.shared.publishWorkstreamEvent(
            event,
            phase: "completed",
            result: result.socketEncodedDictionary
        )
        let payload = result.socketEncodedDictionary
        guard case .object(let bridged)? = JSONValue(foundationObject: payload) else {
            // Unreachable: socketEncodedDictionary always returns a valid JSON
            // object. Report the same encode-failure the legacy `v2Ok` produced
            // for an unencodable payload (an empty `.ok({})`).
            return .delivered(payload: [:])
        }
        return .delivered(payload: bridged)
    }

    /// Delivers a permission decision for `feed.permission.reply`. The worker has
    /// already validated the raw mode against the allow-list; the conformer
    /// reconstructs the `WorkstreamPermissionMode` to call `deliverReply`.
    nonisolated func controlFeedDeliverPermissionReply(requestId: String, modeRawValue: String) {
        guard let mode = WorkstreamPermissionMode(rawValue: modeRawValue) else { return }
        FeedCoordinator.shared.deliverReply(
            requestId: requestId,
            decision: .permission(mode)
        )
    }

    /// Delivers a question decision for `feed.question.reply`.
    nonisolated func controlFeedDeliverQuestionReply(requestId: String, selections: [String]) {
        FeedCoordinator.shared.deliverReply(
            requestId: requestId,
            decision: .question(selections: selections)
        )
    }

    /// Delivers an exit-plan decision for `feed.exit_plan.reply`. The worker has
    /// already validated the raw mode against the allow-list.
    nonisolated func controlFeedDeliverExitPlanReply(
        requestId: String,
        modeRawValue: String,
        feedback: String?
    ) {
        guard let mode = WorkstreamExitPlanMode(rawValue: modeRawValue) else { return }
        FeedCoordinator.shared.deliverReply(
            requestId: requestId,
            decision: .exitPlan(mode, feedback: feedback)
        )
    }

    /// Submits feedback through the composer, blocking the worker thread on a
    /// `DispatchSemaphore` up to the legacy 35-second timeout (the app-coupled
    /// core of `v2FeedbackSubmit` after the `FeedbackSubmissionRequest` parse).
    nonisolated func controlFeedSubmitFeedback(
        email: String,
        message: String,
        imagePaths: [String]
    ) -> ControlFeedbackSubmitOutcome {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var outcome: ControlFeedbackSubmitOutcome = .internalError(
            message: "Feedback submission failed"
        )

        Task {
            let resolved: ControlFeedbackSubmitOutcome
            do {
                let attachmentCount = try await FeedbackComposerBridge().submit(
                    email: email,
                    message: message,
                    imagePaths: imagePaths
                )
                resolved = .submitted(attachmentCount: attachmentCount)
            } catch let error as FeedbackComposerBridgeError {
                switch error {
                case .invalidEmail, .emptyMessage, .messageTooLong, .tooManyImages, .invalidImagePath:
                    resolved = .invalidParams(message: error.localizedDescription)
                case .submissionFailed:
                    resolved = .requestFailed(message: error.localizedDescription)
                }
            } catch {
                resolved = .internalError(message: error.localizedDescription)
            }

            outcome = resolved
            semaphore.signal()
        }

        if semaphore.wait(timeout: .now() + 35) == .timedOut {
            return .timedOut
        }

        return outcome
    }
}

/// Conforms ``ControlFeedWorkerReading`` over a `weak` ``TerminalController``.
///
/// `@unchecked Sendable` (not `@MainActor`): every member must run on the
/// socket-worker thread so the blocking ingest and feedback semaphore never hold
/// the main actor, matching the legacy `nonisolated` `v2FeedPush` /
/// `v2FeedbackSubmit` bodies. The only stored member is a `weak` reference to the
/// app-lifetime `TerminalController` singleton; the controller's resolvers are
/// `nonisolated` and perform their own main-actor hops internally, so no
/// isolation is required on the conformer. The `weak` reference is read on the
/// worker thread, which is safe for a singleton whose lifetime spans every
/// connection.
final class TerminalControllerFeedWorkerReading: ControlFeedWorkerReading, @unchecked Sendable {
    private weak var owner: TerminalController?

    /// Creates the conformer.
    /// - Parameter owner: The controller whose live feed/feedback state backs the
    ///   seam.
    init(owner: TerminalController) {
        self.owner = owner
    }

    func pushEvent(
        eventPayload: [String: JSONValue],
        waitTimeoutSeconds: TimeInterval
    ) -> ControlFeedPushOutcome {
        owner?.controlFeedPushEvent(
            eventPayload: eventPayload,
            waitTimeoutSeconds: waitTimeoutSeconds
        ) ?? .delivered(payload: [:])
    }

    func deliverPermissionReply(requestId: String, modeRawValue: String) {
        owner?.controlFeedDeliverPermissionReply(requestId: requestId, modeRawValue: modeRawValue)
    }

    func deliverQuestionReply(requestId: String, selections: [String]) {
        owner?.controlFeedDeliverQuestionReply(requestId: requestId, selections: selections)
    }

    func deliverExitPlanReply(requestId: String, modeRawValue: String, feedback: String?) {
        owner?.controlFeedDeliverExitPlanReply(
            requestId: requestId,
            modeRawValue: modeRawValue,
            feedback: feedback
        )
    }

    func submitFeedback(
        email: String,
        message: String,
        imagePaths: [String]
    ) -> ControlFeedbackSubmitOutcome {
        owner?.controlFeedSubmitFeedback(
            email: email,
            message: message,
            imagePaths: imagePaths
        ) ?? .internalError(message: "Feedback submission failed")
    }
}
