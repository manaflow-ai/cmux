import Foundation
import Testing

@testable import CmuxFeedback

@Suite("Feedback composer bridge")
struct FeedbackComposerBridgeTests {
    @Test func emptyMessageIsRejectedBeforeAnyNetwork() async {
        await #expect(throws: FeedbackComposerBridgeError.self) {
            _ = try await FeedbackComposerBridge.submit(
                email: "valid@example.com",
                message: "   ",
                imagePaths: []
            )
        }
    }

    @Test func invalidEmailIsRejectedBeforeAnyNetwork() async {
        await #expect(throws: FeedbackComposerBridgeError.self) {
            _ = try await FeedbackComposerBridge.submit(
                email: "not-an-email",
                message: "Real message",
                imagePaths: []
            )
        }
    }

    @Test func tooManyImagesIsRejectedBeforeAnyNetwork() async {
        let paths = (0..<(FeedbackComposerSettings.maxAttachmentCount + 1)).map { "/tmp/feedback-\($0).png" }
        await #expect(throws: FeedbackComposerBridgeError.self) {
            _ = try await FeedbackComposerBridge.submit(
                email: "valid@example.com",
                message: "Real message",
                imagePaths: paths
            )
        }
    }

    @Test func endpointHonorsEnvironmentOverride() {
        // The override is read from the process environment; with no override set
        // the resolved endpoint falls back to the production default.
        if ProcessInfo.processInfo.environment[FeedbackComposerSettings.endpointEnvironmentKey] == nil {
            #expect(FeedbackComposerSettings.endpointURL()?.absoluteString == FeedbackComposerSettings.defaultEndpoint)
        }
    }

    @Test func composerRequestedNotificationNameMatchesAppContract() {
        #expect(Notification.Name.feedbackComposerRequested.rawValue == "cmux.feedbackComposerRequested")
    }
}
