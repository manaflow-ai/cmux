import Foundation
import Testing
@testable import CmuxControlSocket

/// A scriptable ``ControlFeedWorkerReading`` for driving ``ControlFeedWorker``
/// without the app target's feed plumbing. Returns fixed outcomes and records
/// what it was handed so tests can assert the worker's validation, routing, and
/// payload shaping in isolation.
private final class FakeFeedWorkerReading: ControlFeedWorkerReading, @unchecked Sendable {
    var pushOutcome: ControlFeedPushOutcome = .delivered(payload: ["status": .string("acknowledged")])
    var submitOutcome: ControlFeedbackSubmitOutcome = .submitted(attachmentCount: 0)

    private(set) var lastPushEvent: [String: JSONValue]?
    private(set) var lastPushTimeout: TimeInterval?
    private(set) var permissionReplies: [(requestId: String, mode: String)] = []
    private(set) var questionReplies: [(requestId: String, selections: [String])] = []
    private(set) var exitPlanReplies: [(requestId: String, mode: String, feedback: String?)] = []
    private(set) var submitCalls: [(email: String, message: String, imagePaths: [String])] = []

    func pushEvent(eventPayload: [String: JSONValue], waitTimeoutSeconds: TimeInterval) -> ControlFeedPushOutcome {
        lastPushEvent = eventPayload
        lastPushTimeout = waitTimeoutSeconds
        return pushOutcome
    }

    func deliverPermissionReply(requestId: String, modeRawValue: String) {
        permissionReplies.append((requestId, modeRawValue))
    }

    func deliverQuestionReply(requestId: String, selections: [String]) {
        questionReplies.append((requestId, selections))
    }

    func deliverExitPlanReply(requestId: String, modeRawValue: String, feedback: String?) {
        exitPlanReplies.append((requestId, modeRawValue, feedback))
    }

    func submitFeedback(email: String, message: String, imagePaths: [String]) -> ControlFeedbackSubmitOutcome {
        submitCalls.append((email, message, imagePaths))
        return submitOutcome
    }
}

private func request(_ method: String, _ params: [String: JSONValue] = [:]) -> ControlRequest {
    ControlRequest(id: .string("1"), method: method, params: params)
}

@Suite struct ControlFeedWorkerTests {
    @Test func returnsNilForUnownedMethod() {
        let worker = ControlFeedWorker(reading: FakeFeedWorkerReading())
        #expect(worker.handle(request("feed.jump")) == nil)
        #expect(worker.handle(request("system.top")) == nil)
    }

    // MARK: - feed.permission.reply

    @Test func permissionReplyForwardsValidMode() {
        let reading = FakeFeedWorkerReading()
        let worker = ControlFeedWorker(reading: reading)
        let result = worker.handle(request(
            "feed.permission.reply",
            ["request_id": .string("r1"), "mode": .string("always")]
        ))
        #expect(result == .ok(.object(["delivered": .bool(true)])))
        #expect(reading.permissionReplies.count == 1)
        #expect(reading.permissionReplies.first?.requestId == "r1")
        #expect(reading.permissionReplies.first?.mode == "always")
    }

    @Test func permissionReplyRejectsMissingRequestId() {
        let reading = FakeFeedWorkerReading()
        let worker = ControlFeedWorker(reading: reading)
        let result = worker.handle(request("feed.permission.reply", ["mode": .string("once")]))
        #expect(result == .err(
            code: "invalid_params",
            message: "feed.permission.reply requires request_id",
            data: nil
        ))
        #expect(reading.permissionReplies.isEmpty)
    }

    @Test func permissionReplyRejectsUnknownMode() {
        let reading = FakeFeedWorkerReading()
        let worker = ControlFeedWorker(reading: reading)
        let result = worker.handle(request(
            "feed.permission.reply",
            ["request_id": .string("r1"), "mode": .string("nope")]
        ))
        #expect(result == .err(
            code: "invalid_params",
            message: "feed.permission.reply requires mode ∈ once|always|all|bypass|deny",
            data: nil
        ))
        #expect(reading.permissionReplies.isEmpty)
    }

    // MARK: - feed.question.reply

    @Test func questionReplyForwardsStringSelections() {
        let reading = FakeFeedWorkerReading()
        let worker = ControlFeedWorker(reading: reading)
        let result = worker.handle(request(
            "feed.question.reply",
            ["request_id": .string("r2"), "selections": .array([.string("a"), .string("b")])]
        ))
        #expect(result == .ok(.object(["delivered": .bool(true)])))
        #expect(reading.questionReplies.first?.selections == ["a", "b"])
    }

    @Test func questionReplyRejectsNonStringSelections() {
        let reading = FakeFeedWorkerReading()
        let worker = ControlFeedWorker(reading: reading)
        let result = worker.handle(request(
            "feed.question.reply",
            ["request_id": .string("r2"), "selections": .array([.string("a"), .int(3)])]
        ))
        #expect(result == .err(
            code: "invalid_params",
            message: "feed.question.reply requires selections: [string]",
            data: nil
        ))
        #expect(reading.questionReplies.isEmpty)
    }

    // MARK: - feed.exit_plan.reply

    @Test func exitPlanReplyForwardsModeAndFeedback() {
        let reading = FakeFeedWorkerReading()
        let worker = ControlFeedWorker(reading: reading)
        let result = worker.handle(request(
            "feed.exit_plan.reply",
            [
                "request_id": .string("r3"),
                "mode": .string("bypassPermissions"),
                "feedback": .string("looks good"),
            ]
        ))
        #expect(result == .ok(.object(["delivered": .bool(true)])))
        #expect(reading.exitPlanReplies.first?.mode == "bypassPermissions")
        #expect(reading.exitPlanReplies.first?.feedback == "looks good")
    }

    @Test func exitPlanReplyOmitsFeedbackWhenAbsent() {
        let reading = FakeFeedWorkerReading()
        let worker = ControlFeedWorker(reading: reading)
        _ = worker.handle(request(
            "feed.exit_plan.reply",
            ["request_id": .string("r3"), "mode": .string("manual")]
        ))
        #expect(reading.exitPlanReplies.first?.feedback == nil)
    }

    @Test func exitPlanReplyRejectsUnknownMode() {
        let reading = FakeFeedWorkerReading()
        let worker = ControlFeedWorker(reading: reading)
        let result = worker.handle(request(
            "feed.exit_plan.reply",
            ["request_id": .string("r3"), "mode": .string("once")]
        ))
        #expect(result == .err(
            code: "invalid_params",
            message: "feed.exit_plan.reply requires mode ∈ ultraplan|bypassPermissions|autoAccept|manual|deny",
            data: nil
        ))
        #expect(reading.exitPlanReplies.isEmpty)
    }

    // MARK: - feed.push

    @Test func feedPushForwardsNestedEventAndTimeout() {
        let reading = FakeFeedWorkerReading()
        reading.pushOutcome = .delivered(payload: ["status": .string("resolved")])
        let worker = ControlFeedWorker(reading: reading)
        let result = worker.handle(request(
            "feed.push",
            [
                "wait_timeout_seconds": .int(5),
                "event": .object(["session_id": .string("s1")]),
            ]
        ))
        #expect(result == .ok(.object(["status": .string("resolved")])))
        #expect(reading.lastPushEvent == ["session_id": .string("s1")])
        #expect(reading.lastPushTimeout == 5)
    }

    @Test func feedPushAcceptsInlineEventShape() {
        let reading = FakeFeedWorkerReading()
        let worker = ControlFeedWorker(reading: reading)
        let inline: [String: JSONValue] = [
            "session_id": .string("s1"),
            "hook_event_name": .string("Stop"),
            "_source": .string("claude"),
        ]
        _ = worker.handle(request("feed.push", inline))
        #expect(reading.lastPushEvent == inline)
    }

    @Test func feedPushRejectsMissingEvent() {
        let reading = FakeFeedWorkerReading()
        let worker = ControlFeedWorker(reading: reading)
        let result = worker.handle(request("feed.push", ["wait_timeout_seconds": .int(0)]))
        #expect(result == .err(
            code: "invalid_params",
            message: "feed.push requires an `event` object",
            data: nil
        ))
        #expect(reading.lastPushEvent == nil)
    }

    @Test func feedPushRejectsNonNumericTimeout() {
        let reading = FakeFeedWorkerReading()
        let worker = ControlFeedWorker(reading: reading)
        let result = worker.handle(request(
            "feed.push",
            ["wait_timeout_seconds": .string("soon"), "event": .object([:])]
        ))
        #expect(result == .err(
            code: "invalid_params",
            message: "feed.push wait_timeout_seconds must be numeric",
            data: nil
        ))
    }

    @Test func feedPushRejectsOutOfRangeTimeout() {
        let reading = FakeFeedWorkerReading()
        let worker = ControlFeedWorker(reading: reading)
        let result = worker.handle(request(
            "feed.push",
            ["wait_timeout_seconds": .int(999), "event": .object([:])]
        ))
        #expect(result == .err(
            code: "invalid_params",
            message: "feed.push wait_timeout_seconds must be between 0 and 120",
            data: nil
        ))
    }

    @Test func feedPushSurfacesDecodeFailureMessage() {
        let reading = FakeFeedWorkerReading()
        reading.pushOutcome = .decodeFailed(errorDescription: "boom")
        let worker = ControlFeedWorker(reading: reading)
        let result = worker.handle(request("feed.push", ["event": .object([:])]))
        #expect(result == .err(
            code: "invalid_params",
            message: "feed.push event failed to decode: boom",
            data: nil
        ))
    }

    // MARK: - feedback.submit

    @Test func feedbackSubmitForwardsParsedRequest() {
        let reading = FakeFeedWorkerReading()
        reading.submitOutcome = .submitted(attachmentCount: 2)
        let worker = ControlFeedWorker(reading: reading)
        let result = worker.handle(request(
            "feedback.submit",
            [
                "email": .string("a@b.com"),
                "body": .string("hi"),
                "image_paths": .array([.string("/x.png")]),
            ]
        ))
        #expect(result == .ok(.object([
            "submitted": .bool(true),
            "attachment_count": .int(2),
        ])))
        #expect(reading.submitCalls.first?.email == "a@b.com")
        #expect(reading.submitCalls.first?.message == "hi")
        #expect(reading.submitCalls.first?.imagePaths == ["/x.png"])
    }

    @Test func feedbackSubmitReportsMissingFieldOnParseFailure() {
        let reading = FakeFeedWorkerReading()
        let worker = ControlFeedWorker(reading: reading)
        let result = worker.handle(request("feedback.submit", ["body": .string("hi")]))
        #expect(result == .err(
            code: "invalid_params",
            message: "Missing email",
            data: .object(["field": .string("email")])
        ))
        #expect(reading.submitCalls.isEmpty)
    }

    @Test func feedbackSubmitMapsOutcomeCodes() {
        let cases: [(ControlFeedbackSubmitOutcome, String, String)] = [
            (.invalidParams(message: "bad"), "invalid_params", "bad"),
            (.requestFailed(message: "net"), "request_failed", "net"),
            (.internalError(message: "oops"), "internal_error", "oops"),
            (.timedOut, "timeout", "Feedback submission timed out"),
        ]
        for (outcome, code, message) in cases {
            let reading = FakeFeedWorkerReading()
            reading.submitOutcome = outcome
            let worker = ControlFeedWorker(reading: reading)
            let result = worker.handle(request(
                "feedback.submit",
                ["email": .string("a@b.com"), "body": .string("hi")]
            ))
            #expect(result == .err(code: code, message: message, data: nil))
        }
    }
}
