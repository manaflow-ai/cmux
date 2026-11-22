@testable import CmuxNextAgentPane
import CmuxNextDesign
import CmuxNextSettings
import Foundation
import Testing

/// A Cloud start's question waits in its card until the person answers, and never hangs: its start
/// cancelled, its pane closed or a newer question of the same start each end the wait with no answer.
/// Each pane holds its own asks (``AgentPaneModel/cloudAsks``), so another pane can't answer one.
@MainActor @Suite(.serialized)
struct AgentPaneCloudAsksTests {
    private let key = "4D0B6B53-5D7A-4E66-9A39-6E1F0C6C2E11"

    private func question(id: String = "ask-1") -> AgentPaneCloudAsk {
        AgentPaneCloudAsk(id: id, kind: .firstLogin, title: "Set up Claude on paint?", lines: ["One line."],
                          buttons: [.init(id: "cancel", title: "Cancel", role: "cancel"), .init(id: "setUp", title: "Set Up", role: "default")])
    }

    private func answer(_ button: String, id: String = "ask-1") throws -> AgentPaneCloudAnswer {
        try #require(AgentPaneCloudAnswer(params: ["key": key, "id": id, "answer": button]))
    }

    /// Waits until `asks` holds a question (the ask's push ran), so the test answers a waiting one.
    private func shown(_ pushes: AsyncStream<JSONValue>) async {
        for await _ in pushes { break }
    }

    @Test func theClickedButtonEndsTheWaitAndClearsTheCard() async throws {
        let asks = AgentPaneCloudAsks()
        let stream = AsyncStream.makeStream(of: JSONValue.self)
        let pushed = PushedValues()
        let waiting = Task { await asks.ask(question(), start: key) { pushed.values.append($0); stream.continuation.yield($0) } }
        await shown(stream.stream)
        #expect(asks.waitingCount == 1)
        #expect(asks.answer(try answer("setUp")))
        #expect(await waiting.value == "setUp")
        // The second push, made before the wait returns, takes the question out of the card.
        #expect(pushed.values.count == 2)
        #expect(pushed.values.last == .object(["key": .string(key), "ask": .null]))
        #expect(asks.waitingCount == 0)
    }

    @Test func onlyTheWaitingQuestionsOwnButtonsAnswer() async throws {
        let asks = AgentPaneCloudAsks()
        let stream = AsyncStream.makeStream(of: JSONValue.self)
        let waiting = Task { await asks.ask(question(), start: key) { stream.continuation.yield($0) } }
        await shown(stream.stream)
        #expect(!AgentPaneCloudAsks().answer(try answer("setUp"))) // another pane's asks
        #expect(!asks.answer(try answer("setUp", id: "ask-0"))) // an earlier question
        #expect(!asks.answer(try answer("transfer"))) // not one of its buttons
        let decline = try answer("cancel"), yes = try answer("setUp")
        #expect(asks.declines(decline) && !asks.declines(yes))
        #expect(asks.answer(try answer("cancel")))
        #expect(await waiting.value == "cancel")
    }

    @Test func aCancelledStartEndsItsQuestionUnanswered() async throws {
        let asks = AgentPaneCloudAsks()
        let stream = AsyncStream.makeStream(of: JSONValue.self)
        let waiting = Task { await asks.ask(question(), start: key) { stream.continuation.yield($0) } }
        await shown(stream.stream)
        waiting.cancel()
        #expect(await waiting.value == nil)
        #expect(!asks.answer(try answer("setUp")))
    }

    @Test func anAlreadyCancelledStartShowsNothing() async {
        let asks = AgentPaneCloudAsks()
        var pushed = 0
        let waiting = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await asks.ask(question(), start: key) { _ in pushed += 1 }
        }
        #expect(await waiting.value == nil)
        #expect(pushed == 0 && asks.waitingCount == 0)
    }

    @Test func aClosedPaneEndsItsQuestionsUnanswered() async throws {
        let asks = AgentPaneCloudAsks()
        let stream = AsyncStream.makeStream(of: JSONValue.self)
        let waiting = Task { await asks.ask(question(), start: key) { stream.continuation.yield($0) } }
        await shown(stream.stream)
        AgentPaneCloudAsks().endAll() // another pane closing ends nothing
        #expect(asks.waitingCount == 1)
        asks.endAll()
        #expect(await waiting.value == nil)
    }

    @Test func aReloadedPageMovesTheQuestionToItsDialog() async throws {
        let asks = AgentPaneCloudAsks()
        let stream = AsyncStream.makeStream(of: JSONValue.self)
        let asked = AskedQuestions()
        let dialog = AgentPaneCloudAsker { question in
            asked.questions.append(question)
            return "setUp"
        }
        let waiting = Task { await asks.ask(question(), start: key, fallback: dialog) { stream.continuation.yield($0) } }
        await shown(stream.stream)
        asks.pageReloaded()
        #expect(await waiting.value == "setUp")
        #expect(asked.questions == [question()])
        // The reloaded page's old card id answers nothing.
        #expect(!asks.answer(try answer("setUp")))
    }

    @Test func aClosedPaneEndsAMovedQuestionUnanswered() async throws {
        let asks = AgentPaneCloudAsks()
        let stream = AsyncStream.makeStream(of: JSONValue.self)
        let opened = AsyncStream.makeStream(of: Void.self)
        // A dialog no one answers: it ends only when its wait is cancelled.
        let dialog = AgentPaneCloudAsker { _ in
            opened.continuation.yield()
            var never = AsyncStream<String> { _ in }.makeAsyncIterator()
            return await never.next()
        }
        let waiting = Task { await asks.ask(question(), start: key, fallback: dialog) { stream.continuation.yield($0) } }
        await shown(stream.stream)
        asks.pageReloaded()
        var openedIterator = opened.stream.makeAsyncIterator()
        _ = await openedIterator.next()
        asks.endAll()
        #expect(await waiting.value == nil)
    }

    @Test func aPaneClosedRightAfterAReloadOpensNoDialog() async throws {
        let asks = AgentPaneCloudAsks()
        let stream = AsyncStream.makeStream(of: JSONValue.self)
        let asked = AskedQuestions()
        let dialog = AgentPaneCloudAsker { question in
            asked.questions.append(question)
            return "setUp"
        }
        let waiting = Task { await asks.ask(question(), start: key, fallback: dialog) { stream.continuation.yield($0) } }
        await shown(stream.stream)
        // Both run before the wait resumes: the pane is gone by the time it would ask in a dialog.
        asks.pageReloaded()
        asks.endAll()
        #expect(await waiting.value == nil)
        #expect(asked.questions.isEmpty)
    }

    @Test func aNewerQuestionOfTheSameStartEndsTheEarlierOne() async throws {
        let asks = AgentPaneCloudAsks()
        let first = AsyncStream.makeStream(of: JSONValue.self), second = AsyncStream.makeStream(of: JSONValue.self)
        let earlier = Task { await asks.ask(question(), start: key) { first.continuation.yield($0) } }
        await shown(first.stream)
        let later = Task { await asks.ask(question(id: "ask-2"), start: key) { second.continuation.yield($0) } }
        #expect(await earlier.value == nil)
        await shown(second.stream)
        #expect(asks.answer(try answer("setUp", id: "ask-2")))
        #expect(await later.value == "setUp")
    }

    @Test func theAnswerRequestTakesOnlyAStartKeyAnIdAndAButton() {
        #expect(AgentPaneCloudAnswer(params: ["key": key, "id": "a", "answer": "setUp"]) != nil)
        #expect(AgentPaneCloudAnswer(params: ["key": "not-a-uuid", "id": "a", "answer": "setUp"]) == nil)
        #expect(AgentPaneCloudAnswer(params: ["key": key, "id": "", "answer": "setUp"]) == nil)
        #expect(AgentPaneCloudAnswer(params: ["key": key, "id": "a"]) == nil)
        if case .cloudAnswerStart = AgentPaneRequest(body: ["method": "cloud.answerStart", "params": ["key": key, "id": "a", "answer": "b"]]) {} else {
            Issue.record("cloud.answerStart did not decode")
        }
    }

    @Test func aDialogSpecBecomesTheCardsQuestionWithItsLinkAndCode() throws {
        let spec = CmuxDialogSpec(title: "Use my login?", lines: ["Body."],
                                  buttons: [.cancel("Don't Use"), CmuxDialogButton(id: "use", title: "Use My Login", role: .default)],
                                  identifier: "cmux.dialog.test")
        let link = try #require(URL(string: "https://example.com/device"))
        let ask = AgentPaneCloudAsk(kind: .loginCopy, spec: spec, code: "ABCD-1234", link: link, linkTitle: "Open sign-in")
        #expect(ask.buttons.map(\.role) == ["cancel", "default"])
        #expect(ask.cancelID == ask.buttons.first?.id)
        // Shown as a dialog again: the link becomes the default button between cancel and the rest.
        let shown = AgentPaneCloudAsker.spec(ask)
        #expect(shown.buttons.map(\.id) == [ask.cancelID, AgentPaneCloudAsker.linkButton, "use"])
        #expect(shown.buttons.map(\.role) == [.cancel, .default, .normal])
        #expect(shown.identifier == "cmux.dialog.test")
        guard case .object(let json) = ask.json else { Issue.record("not an object"); return }
        #expect(json["identifier"] == nil)
        #expect(json["kind"] == .string("loginCopy") && json["code"] == .string("ABCD-1234"))
        #expect(json["link"] == .object(["url": .string(link.absoluteString), "title": .string("Open sign-in")]))
    }
}

/// What a test's ask pushed to its card, in order.
@MainActor private final class PushedValues {
    var values: [JSONValue] = []
}

/// The questions a test's dialog was asked, in order.
@MainActor private final class AskedQuestions {
    var questions: [AgentPaneCloudAsk] = []
}
