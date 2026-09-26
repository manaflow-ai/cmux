import Testing
@testable import CmuxAgentHooks

@Suite("Agent hook abnormal-stop classifier")
struct AgentHookAbnormalStopClassifierTests {
    private let classifier = AgentHookAbnormalStopClassifier()

    @Test(arguments: [
        ("Selected model is at capacity. Please try again.", AgentHookAbnormalStopClass.capacity),
        ("server overloaded", .capacity),
        ("quota exceeded", .quota),
        ("429 Too Many Requests", .rateLimit),
        ("429 Too Many Requests: rate limit exceeded", .rateLimit),
        ("request timed out", .timeout),
        ("■ request timed out", .timeout),
        ("request timeout", .timeout),
        ("deadline exceeded", .timeout),
        ("authentication token expired", .authentication),
        ("network error: connection reset", .network),
        ("API error: request failed", .generic),
    ] as [(String, AgentHookAbnormalStopClass)])
    func classifiesProviderStopBanners(entry: (String, AgentHookAbnormalStopClass)) {
        let (message, expected) = entry
        #expect(classifier.abnormalStopClass(signal: "Stop", message: message) == expected)
    }

    @Test func ignoresLocalAndHistoricalProse() {
        let messages = [
            "The local job queue is at capacity",
            "The report says quota exceeded for a previous run.",
            "The first request timed out, but the retry completed successfully.",
            "request timeout handling",
            "API error handling",
        ]
        for message in messages {
            #expect(classifier.abnormalStopClass(signal: "Stop", message: message) == nil)
        }
    }

    @Test func userCancellationWinsOverStaleProviderText() {
        #expect(classifier.isUserInitiatedStop(
            signal: "Stop",
            message: "Selected model is at capacity; interrupted by user (Ctrl+C)"
        ))
        #expect(classifier.abnormalStopClass(
            signal: "Stop",
            message: "Selected model is at capacity; interrupted by user (Ctrl+C)"
        ) == nil)
    }

    @Test func recognizesStructuredUserRequestedReasonWithEventName() {
        #expect(classifier.isUserInitiatedStop(
            signal: "Stop user_requested task_complete",
            message: "Selected model is at capacity"
        ))
        #expect(classifier.isUserInitiatedStop(
            signal: "Stop capacity",
            message: "completed capacity user_requested"
        ))
        #expect(!classifier.isUserInitiatedStop(
            signal: "Stop",
            message: "Approve the command the user requested"
        ))
    }

    @Test func doesNotTreatInstructionalOrProviderCancellationProseAsUserAbort() {
        #expect(!classifier.isUserInitiatedStop(
            signal: "Stop",
            message: "Press Ctrl+C to stop the server"
        ))
        #expect(!classifier.isUserInitiatedStop(
            signal: "Stop",
            message: "cancelled"
        ))
        #expect(!classifier.isUserInitiatedStop(
            signal: "Stop",
            message: "The provider cancelled the request"
        ))
        #expect(!classifier.isUserInitiatedStop(
            signal: "Stop provider interrupted turn_aborted",
            message: "API error: interrupted by provider"
        ))
        #expect(classifier.abnormalStopClass(
            signal: "Stop provider interrupted turn_aborted",
            message: "API error: interrupted by provider"
        ) == .generic)
    }

    @Test func requiresProviderContextForAmbiguousFailureProse() {
        #expect(classifier.abnormalStopClass(
            signal: "Stop",
            message: "The guide explains rate limit handling"
        ) == nil)
        #expect(classifier.abnormalStopClass(
            signal: "Stop",
            message: "rate limit"
        ) == .rateLimit)
        #expect(classifier.abnormalStopClass(
            signal: "Stop",
            message: "The API request hit a rate limit"
        ) == .rateLimit)
        #expect(classifier.abnormalStopClass(
            signal: "Stop",
            message: "The guide explains that session expired means sign-in is needed"
        ) == nil)
        #expect(classifier.abnormalStopClass(
            signal: "Stop",
            message: "session expired"
        ) == .authentication)
    }

    @Test func recognizesStructuredProviderReasonsWithoutMessage() {
        #expect(classifier.abnormalStopClass(signal: "Stop rate_limit", message: "") == .rateLimit)
        #expect(classifier.abnormalStopClass(signal: "Stop capacity", message: "") == .capacity)
        #expect(classifier.abnormalStopClass(signal: "Stop overload", message: "") == .capacity)
        #expect(classifier.abnormalStopClass(signal: "Stop timeout", message: "") == .timeout)
        #expect(classifier.abnormalStopClass(signal: "Stop unauthorized", message: "") == .authentication)
        #expect(classifier.abnormalStopClass(signal: "Stop connection refused", message: "") == .network)
    }

    @Test func recognizesBannerMarkersAndShortQuotaReasons() {
        #expect(classifier.abnormalStopClass(signal: "Stop", message: "■ rate limited") == .rateLimit)
        #expect(classifier.abnormalStopClass(signal: "Stop", message: "■ 429 Too Many Requests") == .rateLimit)
        #expect(classifier.abnormalStopClass(signal: "Stop", message: "■ capacity") == .capacity)
        #expect(classifier.abnormalStopClass(signal: "Stop", message: "■ overloaded") == .capacity)
        #expect(classifier.abnormalStopClass(signal: "Stop", message: "■ 529") == .capacity)
        #expect(classifier.abnormalStopClass(signal: "Stop", message: "quota") == .quota)
        #expect(classifier.abnormalStopClass(signal: "Stop quota", message: "") == .quota)
        #expect(classifier.abnormalStopClass(signal: "Stop", message: "hit your limit") == .quota)
        #expect(classifier.abnormalStopClass(signal: "Stop", message: "you've hit your limit") == .quota)
    }

    @Test func embeddedStatusCodesAndSensitiveDetailsFailClosed() {
        #expect(classifier.abnormalStopClass(signal: "Stop", message: "request-429-attempt") == nil)
        #expect(classifier.abnormalStopClass(signal: "Stop", message: "correlation_id=abc529xyz") == nil)
        #expect(classifier.isSensitiveProviderDetail("API error request_id=abc123") == true)
        #expect(classifier.isSensitiveProviderDetail("The provider stopped unexpectedly") == false)
    }

    @Test func ignoresUnqualifiedFailureProse() {
        #expect(classifier.abnormalStopClass(
            signal: "Stop",
            message: "Fixed the error: missing import"
        ) == nil)
        #expect(classifier.abnormalStopClass(
            signal: "Stop",
            message: "The tests failed: exit 1"
        ) == nil)
        #expect(classifier.abnormalStopClass(
            signal: "Stop",
            message: "The API response failed: invalid payload"
        ) == .generic)
    }

    @Test func matchesStructuredUserRequestedReasonCaseInsensitively() {
        #expect(classifier.isUserInitiatedStop(
            signal: "Stop capacity USER_REQUESTED",
            message: ""
        ))
        #expect(classifier.abnormalStopClass(
            signal: "Stop capacity USER_REQUESTED",
            message: ""
        ) == nil)
    }
}
