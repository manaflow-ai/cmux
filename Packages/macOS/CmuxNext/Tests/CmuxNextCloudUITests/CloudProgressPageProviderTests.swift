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

    @Test func aQuestionOnThePageIsAnsweredOnceByThePerson() async throws {
        let provider = CloudProgressPageProvider(source: Source(), actions: .init(retry: {}, dismiss: {}, copy: { _ in }, personOnlyMessage: "no"))
        var answers: [Bool] = []
        let ask = CloudProgressAsk(id: "a1", kind: .createRequest, title: "Create?", body: "An agent asked.", button: "Create", cancel: "Cancel")
        provider.ask(ask) { answers.append($0) }
        #expect(provider.state()["ask"]?["id"] == .string("a1"))
        let answer: JSONValue = .object(["id": .string("a1"), "accept": .bool(true)])
        await #expect(throws: PageError.self) {
            _ = try await provider.call(CloudProgressPageProvider.answerOp, params: answer, context: PageCallContext(page: "cmux.cloud-progress"))
        }
        // Another question's id answers nothing.
        _ = try await provider.call(CloudProgressPageProvider.answerOp, params: .object(["id": .string("other"), "accept": .bool(true)]),
                                    context: PageCallContext(page: "cmux.cloud-progress", userGesture: true))
        #expect(answers.isEmpty)
        _ = try await provider.call(CloudProgressPageProvider.answerOp, params: answer, context: PageCallContext(page: "cmux.cloud-progress", userGesture: true))
        #expect(answers == [true])
        #expect(provider.state()["ask"] == .null)
    }

    @Test func dismissAndANewerQuestionAnswerTheOpenOneNo() async throws {
        var dismissed = 0
        let provider = CloudProgressPageProvider(source: Source(), actions: .init(retry: {}, dismiss: { dismissed += 1 }, copy: { _ in }, personOnlyMessage: "no"))
        var answers: [String] = []
        provider.ask(CloudProgressAsk(id: "a1", kind: .approval, title: "t", body: "b", button: "Create", cancel: "Cancel")) { answers.append("a1:\($0)") }
        provider.ask(CloudProgressAsk(id: "a2", kind: .upgrade, title: "t", body: "b", button: "Upgrade", cancel: "Cancel")) { answers.append("a2:\($0)") }
        _ = try await provider.call(CloudProgressPageProvider.dismissOp, params: .object([:]), context: PageCallContext(page: "cmux.cloud-progress", userGesture: true))
        #expect(answers == ["a1:false", "a2:false"])
        #expect(dismissed == 1)
    }

    @Test(.timeLimit(.minutes(1))) func aCancelledWaitTakesTheQuestionOffThePage() async {
        let provider = CloudProgressPageProvider(source: Source(), actions: .init(retry: {}, dismiss: {}, copy: { _ in }, personOnlyMessage: "no"))
        let wait = Task { await provider.ask(CloudProgressAsk(id: "a1", kind: .approval, title: "t", body: "b", button: "Create", cancel: "Cancel")) }
        while provider.shownAsk == nil { await Task.yield() }
        wait.cancel()
        #expect(await wait.value == false)
        #expect(provider.shownAsk == nil)
    }
}
