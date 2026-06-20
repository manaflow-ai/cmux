internal import Foundation

/// The worker-lane RPC handler for the feed/feedback control commands
/// (`feed.push`, `feed.permission.reply`, `feed.question.reply`,
/// `feed.exit_plan.reply`, `feedback.submit`), lifted byte-faithfully from the
/// former `TerminalController.v2FeedPush` / `v2Feed*Reply` / `v2FeedbackSubmit`
/// bodies.
///
/// Owns the command dispatch, the parameter validation (including the exact
/// error codes/messages and the `mode` raw-value allow-lists), and the result
/// payloads (the typed ``JSONValue`` twins of the legacy `[String: Any]`
/// dictionaries; the resulting Foundation object, and therefore the encoded wire
/// bytes, is identical). The app-coupled work (decoding the workstream event,
/// publishing to `CmuxEventBus`, the iMessage-mode side effects, the blocking
/// `FeedCoordinator` ingest/reply delivery, and the feedback composer
/// submission) is reached strictly through the ``ControlFeedWorkerReading`` seam.
/// It does no socket I/O and never imports the app target.
///
/// ## Isolation
///
/// `Sendable` and synchronous, NOT `@MainActor`: these commands run on the
/// nonisolated socket-worker lane and block the worker thread (a `feed.push`
/// with `wait_timeout_seconds > 0` parks until the user replies; `feedback.submit`
/// blocks up to 35 seconds). ``handle(_:)`` and the seam are synchronous and run
/// on the calling worker thread, exactly as the legacy `nonisolated` bodies did;
/// the seam's main-actor hops and blocking waits stay inside the conformer.
public struct ControlFeedWorker: Sendable {
    /// The validated `mode` raw values a `feed.permission.reply` accepts, matching
    /// `WorkstreamPermissionMode`'s cases exactly (`once|always|all|bypass|deny`).
    /// Encoded here as wire-format knowledge so the package needs no dependency on
    /// the app's `WorkstreamPermissionMode`; the conformer re-validates by
    /// constructing the enum from this raw value.
    private static let permissionModeRawValues: Set<String> = [
        "once", "always", "all", "bypass", "deny",
    ]

    /// The validated `mode` raw values a `feed.exit_plan.reply` accepts, matching
    /// `WorkstreamExitPlanMode`'s cases exactly
    /// (`ultraplan|bypassPermissions|autoAccept|manual|deny`).
    private static let exitPlanModeRawValues: Set<String> = [
        "ultraplan", "bypassPermissions", "autoAccept", "manual", "deny",
    ]

    /// The live feed/feedback seam. Injected at construction.
    private let reading: any ControlFeedWorkerReading

    /// Creates a worker.
    ///
    /// - Parameter reading: The feed/feedback seam to read/drive.
    public init(reading: any ControlFeedWorkerReading) {
        self.reading = reading
    }

    /// Runs one decoded request if it is a feed/feedback worker-lane command,
    /// returning the typed result; returns `nil` for any other method so the
    /// caller can fall through.
    ///
    /// - Parameter request: The decoded request envelope.
    /// - Returns: The command result, or `nil` if not an owned method.
    public func handle(_ request: ControlRequest) -> ControlCallResult? {
        switch request.method {
        case "feedback.submit":
            return feedbackSubmit(request.params)
        case "feed.push":
            return feedPush(request.params)
        case "feed.permission.reply":
            return feedPermissionReply(request.params)
        case "feed.question.reply":
            return feedQuestionReply(request.params)
        case "feed.exit_plan.reply":
            return feedExitPlanReply(request.params)
        default:
            return nil
        }
    }

    // MARK: - feedback.submit

    /// `feedback.submit` — `v2FeedbackSubmit`. Validates the params via
    /// ``FeedbackSubmissionRequest`` (reporting the `["field": …]` payload on a
    /// parse failure), drives the blocking composer through the seam, and maps the
    /// outcome to the legacy result codes.
    private func feedbackSubmit(_ params: [String: JSONValue]) -> ControlCallResult {
        let request: FeedbackSubmissionRequest
        do {
            request = try FeedbackSubmissionRequest(params: foundationDict(params))
        } catch let error as FeedbackSubmissionRequest.ParseError {
            return .err(
                code: "invalid_params",
                message: error.message,
                data: .object(["field": .string(error.field)])
            )
        } catch {
            return .err(code: "invalid_params", message: error.localizedDescription, data: nil)
        }

        let outcome = reading.submitFeedback(
            email: request.email,
            message: request.body,
            imagePaths: request.imagePaths
        )
        switch outcome {
        case .submitted(let attachmentCount):
            return .ok(.object([
                "submitted": .bool(true),
                "attachment_count": .int(Int64(attachmentCount)),
            ]))
        case .invalidParams(let message):
            return .err(code: "invalid_params", message: message, data: nil)
        case .requestFailed(let message):
            return .err(code: "request_failed", message: message, data: nil)
        case .internalError(let message):
            return .err(code: "internal_error", message: message, data: nil)
        case .timedOut:
            return .err(code: "timeout", message: "Feedback submission timed out", data: nil)
        }
    }

    // MARK: - feed.push

    /// `feed.push` — `v2FeedPush`. Parses and bounds-checks `wait_timeout_seconds`
    /// (via ``FeedPushWaitTimeout``), resolves the `event` object (nested or
    /// inline), and hands the app-coupled decode/publish/ingest to the seam.
    private func feedPush(_ params: [String: JSONValue]) -> ControlCallResult {
        let waitTimeout: TimeInterval
        switch FeedPushWaitTimeout.parse(rawValue: params["wait_timeout_seconds"]?.foundationObject) {
        case .success(let timeout):
            waitTimeout = timeout.seconds
        case .failure(.nonNumeric):
            return .err(
                code: "invalid_params",
                message: "feed.push wait_timeout_seconds must be numeric",
                data: nil
            )
        case .failure(.outOfRange):
            return .err(
                code: "invalid_params",
                message: "feed.push wait_timeout_seconds must be between 0 and 120",
                data: nil
            )
        }

        let eventPayload: [String: JSONValue]
        if case .object(let nested)? = params["event"] {
            eventPayload = nested
        } else if params["session_id"] != nil,
                  params["hook_event_name"] != nil,
                  params["_source"] != nil {
            eventPayload = params
        } else {
            return .err(
                code: "invalid_params",
                message: "feed.push requires an `event` object",
                data: nil
            )
        }

        switch reading.pushEvent(eventPayload: eventPayload, waitTimeoutSeconds: waitTimeout) {
        case .delivered(let payload):
            return .ok(.object(payload))
        case .decodeFailed(let errorDescription):
            return .err(
                code: "invalid_params",
                message: "feed.push event failed to decode: \(errorDescription)",
                data: nil
            )
        }
    }

    // MARK: - feed.*.reply

    /// `feed.permission.reply` — `v2FeedPermissionReply`. Requires a string
    /// `request_id` and a `mode` in the permission allow-list.
    private func feedPermissionReply(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let requestId = rawString(params, "request_id") else {
            return .err(
                code: "invalid_params",
                message: "feed.permission.reply requires request_id",
                data: nil
            )
        }
        guard let modeRaw = rawString(params, "mode"),
              Self.permissionModeRawValues.contains(modeRaw)
        else {
            return .err(
                code: "invalid_params",
                message: "feed.permission.reply requires mode ∈ once|always|all|bypass|deny",
                data: nil
            )
        }
        reading.deliverPermissionReply(requestId: requestId, modeRawValue: modeRaw)
        return .ok(.object(["delivered": .bool(true)]))
    }

    /// `feed.question.reply` — `v2FeedQuestionReply`. Requires a string
    /// `request_id` and a `selections` array of strings.
    private func feedQuestionReply(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let requestId = rawString(params, "request_id") else {
            return .err(
                code: "invalid_params",
                message: "feed.question.reply requires request_id",
                data: nil
            )
        }
        guard let selections = stringArray(params, "selections") else {
            return .err(
                code: "invalid_params",
                message: "feed.question.reply requires selections: [string]",
                data: nil
            )
        }
        reading.deliverQuestionReply(requestId: requestId, selections: selections)
        return .ok(.object(["delivered": .bool(true)]))
    }

    /// `feed.exit_plan.reply` — `v2FeedExitPlanReply`. Requires a string
    /// `request_id` and a `mode` in the exit-plan allow-list, with optional
    /// `feedback`.
    private func feedExitPlanReply(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let requestId = rawString(params, "request_id") else {
            return .err(
                code: "invalid_params",
                message: "feed.exit_plan.reply requires request_id",
                data: nil
            )
        }
        guard let modeRaw = rawString(params, "mode"),
              Self.exitPlanModeRawValues.contains(modeRaw)
        else {
            return .err(
                code: "invalid_params",
                message: "feed.exit_plan.reply requires mode ∈ ultraplan|bypassPermissions|autoAccept|manual|deny",
                data: nil
            )
        }
        let feedback = rawString(params, "feedback")
        reading.deliverExitPlanReply(requestId: requestId, modeRawValue: modeRaw, feedback: feedback)
        return .ok(.object(["delivered": .bool(true)]))
    }

    // MARK: - Param helpers (byte-faithful twins of the legacy `as?` reads)

    /// The faithful twin of `params[key] as? String`: only a JSON string counts
    /// (no trimming, no coercion). Mirrors the legacy reply bodies' raw
    /// `params["request_id"] as? String` / `params["mode"] as? String` reads.
    private func rawString(_ params: [String: JSONValue], _ key: String) -> String? {
        guard case .string(let value)? = params[key] else { return nil }
        return value
    }

    /// The faithful twin of `params[key] as? [String]`: a JSON array whose every
    /// element is a string (a mixed array fails, matching the legacy cast).
    private func stringArray(_ params: [String: JSONValue], _ key: String) -> [String]? {
        guard case .array(let values)? = params[key] else { return nil }
        var result: [String] = []
        result.reserveCapacity(values.count)
        for value in values {
            guard case .string(let string) = value else { return nil }
            result.append(string)
        }
        return result
    }

    /// Bridges a `JSONValue` param dictionary to the Foundation `[String: Any]`
    /// shape ``FeedbackSubmissionRequest`` validates against, matching the legacy
    /// body which read Foundation-bridged params directly.
    private func foundationDict(_ params: [String: JSONValue]) -> [String: Any] {
        params.mapValues { $0.foundationObject }
    }
}
