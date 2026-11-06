import CmuxNextCloudUI
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

/// The Cloud progress page's provider: the step a failure stopped at, and actions only from the person.
@MainActor
struct CloudProgressPageProviderTests {
    final class Source: CloudProgressSource {
        var progressStage = "booting"
        var progressStepIndex: Int? = 2
        let progressSteps = ["requesting", "creating", "booting", "connecting", "ready"]
        var progressFailure: String?
        var progressIdle = false
        var progressMachine: String? = "paint-dev"
        var progressFinished = false
        func progressElapsed() -> Duration { .milliseconds(12_500) }
        var progressChangeKey: String { progressStage }
    }

    @Test func aFailureKeepsTheStepItStoppedAt() {
        let source = Source()
        let provider = CloudProgressPageProvider(source: source, actions: .init(retry: {}, dismiss: {}, copy: { _ in }, personOnlyMessage: "no"))
        #expect(provider.state()["step"] == .number(2))
        (source.progressStage, source.progressStepIndex, source.progressFailure) = ("failed", nil, "link closed")
        let failed = provider.state()
        #expect(failed["step"] == .number(2), "the failure moved the step it stopped at")
        #expect(failed["failure"] == .string("link closed"))
        #expect(failed["elapsedMs"] == .number(12_500))
        #expect(failed["machine"] == .string("paint-dev"))
    }

    @Test func actionsRunOnlyFromThePersonsOwnClickOrKey() async throws {
        let source = Source()
        source.progressFailure = "link closed"
        var ran: [String] = []
        let provider = CloudProgressPageProvider(source: source, actions: .init(
            retry: { ran.append("retry") }, dismiss: { ran.append("dismiss") }, copy: { ran.append("copy:\($0)") }, personOnlyMessage: "no"))
        for op in [CloudProgressPageProvider.retryOp, CloudProgressPageProvider.dismissOp, CloudProgressPageProvider.copyErrorOp] {
            await #expect(throws: PageError.self) {
                _ = try await provider.call(op, params: .object([:]), context: PageCallContext(page: "cmux.cloud-progress"))
            }
            _ = try await provider.call(op, params: .object([:]), context: PageCallContext(page: "cmux.cloud-progress", userGesture: true))
        }
        #expect(ran == ["retry", "dismiss", "copy:link closed"])
    }
}
