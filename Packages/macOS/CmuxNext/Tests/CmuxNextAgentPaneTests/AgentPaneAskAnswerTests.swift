import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The home's inbox answers another chat's ask in place (`chat.asks.answer`, ``AgentPaneAskAnswer``).
/// Leo (2026-10-26): "that we don't accidentally soft lock or hard lock or, like, goodness forbid,
/// um, send, like, an incorrect thing". So it answers only on the person's own fresh click, once per
/// click, an ask still pending in another chat on this pane's own acpmux, with that ask's allow once
/// or deny once, and nothing else.
@MainActor
struct AgentPaneAskAnswerTests {
    private static let socket = "/tmp/acpmux-main.sock"
    private static let environment = AcpmuxEnvironment(executable: URL(fileURLWithPath: "/usr/bin/true"),
                                                       home: URL(fileURLWithPath: "/tmp/acpmux-home"), socketPath: socket,
                                                       daemonArguments: [], childEnvironment: [:])

    /// A host whose daemon listens on `socket`.
    private actor Host: AgentPaneHostProviding {
        let socket: String?
        let environment: AcpmuxEnvironment
        init(socket: String?, environment: AcpmuxEnvironment) { (self.socket, self.environment) = (socket, environment) }
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
        func answerEnvironment(socket: String) async -> AcpmuxEnvironment? {
            socket == self.socket ? environment : nil
        }
    }

    /// acpmux as the answerer sees it: the asks pending, and every read and answer.
    private final class Answerer: AgentAskAnswering {
        var pending: [String: AgentPendingAsk] = [:]
        var reads: [String] = []
        var answers: [(session: String, permission: String, allow: Bool)] = []

        func pendingAsk(session: String, permission: String) async -> AgentPendingAsk? {
            reads.append("\(session) \(permission)")
            return pending["\(session) \(permission)"]
        }

        /// The ask leaves between the read and the answer (answered elsewhere, withdrawn).
        var goneBeforeAnswer = false

        func answerOnce(_ approval: AgentApproval, allow: Bool, spend: @MainActor () -> Bool) async -> Bool {
            let key = "\(approval.session) \(approval.permission)"
            if goneBeforeAnswer { pending[key] = nil }
            guard pending[key] != nil, spend() else { return false }
            pending[key] = nil
            answers.append((approval.session, approval.permission, allow))
            return true
        }
    }

    private final class Clock { var now: TimeInterval = 100 }

    /// A home (no chat of its own) on this Mac's acpmux, and acpmux with one ask of `tests` open.
    private static func home(chat: String? = nil, socket: String? = socket) -> (AgentPaneModel, Answerer, Clock) {
        let clock = Clock()
        let model = AgentPaneModel(host: Host(socket: socket, environment: environment), sessionId: chat,
                                   transport: AgentPaneTransport(gestures: AgentPaneUserGestures(now: { clock.now })))
        model.transport.acpmuxSocket = socket
        let answerer = Answerer()
        answerer.pending["local/tests p1"] = AgentPendingAsk(
            approval: AgentApproval(session: "local/tests", permission: "p1", digest: "d1", summary: "Run the tests"),
            allowOnce: "allow_once", denyOnce: "reject_once")
        return (model, answerer, clock)
    }

    private static func ask(_ session: String = "tests", _ permission: String = "p1", option: String) -> AgentPaneAskAnswer {
        AgentPaneAskAnswer(["sessionId": session, "permissionId": permission, "optionId": option])!
    }

    private static func send(_ ask: AgentPaneAskAnswer, _ model: AgentPaneModel, _ answerer: Answerer) async -> [String: Any] {
        await ask.respond(in: model) { _ in answerer }
    }

    private static func code(_ reply: [String: Any]) -> String? {
        reply["ok"] as? Bool == true ? nil : (reply["error"] as? [String: Any])?["code"] as? String
    }

    @Test func aClickAnswersThatAsksOwnAllowOrDenyOnceOnThisMacsAcpmux() async {
        #expect(AgentPageOps.all.contains("cmux.agent.chat.asks.answer"))
        let (model, answerer, _) = Self.home()
        model.transport.gestures.record(click: true)
        #expect(Self.code(await Self.send(Self.ask(option: "allow_once"), model, answerer)) == nil)
        #expect(answerer.answers.map { "\($0.session) \($0.permission) \($0.allow)" } == ["local/tests p1 true"])
        // A deny, named by its bare id or `local/`, is the deny once.
        answerer.pending["local/tests p2"] = AgentPendingAsk(
            approval: AgentApproval(session: "local/tests", permission: "p2", digest: "d2", summary: "Delete the cache"),
            allowOnce: "allow_once", denyOnce: "reject_once")
        model.transport.gestures.record(click: true)
        #expect(Self.code(await Self.send(Self.ask("local/tests", "p2", option: "reject_once"), model, answerer)) == nil)
        #expect(answerer.answers.last.map { "\($0.permission) \($0.allow)" } == "p2 false")
    }

    /// No click, a click too old, a keystroke, and a second answer on one click answer nothing,
    /// and none of them reads acpmux either.
    @Test func onlyAFreshClickAnswersAndEachClickAnswersOnce() async {
        let (model, answerer, clock) = Self.home()
        #expect(Self.code(await Self.send(Self.ask(option: "allow_once"), model, answerer)) == "refused", "no gesture")
        model.transport.gestures.record()
        #expect(Self.code(await Self.send(Self.ask(option: "allow_once"), model, answerer)) == "refused", "a keystroke")
        model.transport.gestures.record(click: true)
        clock.now += AgentPaneUserGestures.answerWindow + 0.1
        #expect(Self.code(await Self.send(Self.ask(option: "allow_once"), model, answerer)) == "refused", "a stale click")
        #expect(answerer.reads.isEmpty && answerer.answers.isEmpty)
        model.transport.gestures.record(click: true)
        answerer.pending["local/tests p2"] = answerer.pending["local/tests p1"].map {
            var next = $0
            next.approval.permission = "p2"
            return next
        }
        #expect(Self.code(await Self.send(Self.ask(option: "allow_once"), model, answerer)) == nil)
        #expect(Self.code(await Self.send(Self.ask("tests", "p2", option: "allow_once"), model, answerer)) == "refused", "the same click")
        #expect(answerer.answers.count == 1)
    }

    /// Typing after a click records a new grant, but not a new click: the click that answered
    /// one ask answers no other.
    @Test func typingAfterTheClickDoesNotLetItAnswerAgain() async {
        let (model, answerer, _) = Self.home()
        answerer.pending["local/tests p2"] = AgentPendingAsk(
            approval: AgentApproval(session: "local/tests", permission: "p2", digest: "d2", summary: "Delete the cache"),
            allowOnce: "allow_once", denyOnce: "reject_once")
        model.transport.gestures.record(click: true)
        #expect(Self.code(await Self.send(Self.ask(option: "allow_once"), model, answerer)) == nil)
        model.transport.gestures.record()
        #expect(Self.code(await Self.send(Self.ask("tests", "p2", option: "allow_once"), model, answerer)) == "refused")
        #expect(answerer.answers.count == 1)
    }

    /// A refusal (an ask no longer pending, an option it does not offer) leaves the click, so the
    /// row or the chat's card can still answer with it.
    @Test func aRefusalDoesNotSpendTheClick() async {
        let (model, answerer, _) = Self.home()
        model.transport.gestures.record(click: true)
        #expect(Self.code(await Self.send(Self.ask("tests", "gone", option: "allow_once"), model, answerer)) == "refused")
        #expect(Self.code(await Self.send(Self.ask(option: "allow_always"), model, answerer)) == "refused")
        #expect(Self.code(await Self.send(Self.ask(option: "reject_once"), model, answerer)) == nil)
        #expect(answerer.answers.map { "\($0.permission) \($0.allow)" } == ["p1 false"])
    }

    /// An ask that leaves between the read and the answer is refused, and the click stays for the
    /// next answer.
    @Test func anAskGoneBeforeTheAnswerLeavesTheClick() async {
        let (model, answerer, _) = Self.home()
        model.transport.gestures.record(click: true)
        answerer.goneBeforeAnswer = true
        #expect(Self.code(await Self.send(Self.ask(option: "allow_once"), model, answerer)) == "refused")
        #expect(model.transport.gestures.hasFreshAnswerGesture)
        answerer.goneBeforeAnswer = false
        answerer.pending["local/tests p2"] = AgentPendingAsk(
            approval: AgentApproval(session: "local/tests", permission: "p2", digest: "d2", summary: "Delete the cache"),
            allowOnce: "allow_once", denyOnce: "reject_once")
        #expect(Self.code(await Self.send(Self.ask("tests", "p2", option: "allow_once"), model, answerer)) == nil)
        #expect(answerer.answers.map(\.permission) == ["p2"])
    }

    /// A deny is the ask's reject once only: an ask that offers only Always deny has no deny
    /// here (``AcpmuxPermissionPrompt/onceOption(allow:offered:)``), so its chat's card answers it.
    @Test func aDenyIsRejectOnceNeverRejectAlways() {
        let options: [[String: Any]] = [["optionId": "yes", "kind": "allow_once"], ["optionId": "never", "kind": "reject_always"]]
        #expect(AcpmuxPermissionPrompt.onceOption(allow: true, offered: options) == "yes")
        #expect(AcpmuxPermissionPrompt.onceOption(allow: false, offered: options) == nil)
        #expect(AcpmuxPermissionPrompt.option(allow: false, offered: options) == "never", "the banner's mapping, unchanged")
    }

    /// An option that is not the ask's allow once or deny once (Always allow, another option, an
    /// option of another ask) and an ask no longer pending answer nothing.
    @Test func onlyTheAsksOneClickOptionsAndOnlyWhileItIsPending() async {
        let (model, answerer, _) = Self.home()
        for option in ["allow_always", "reject_always", "p9-yes"] {
            model.transport.gestures.record(click: true)
            #expect(Self.code(await Self.send(Self.ask(option: option), model, answerer)) == "refused", "\(option)")
        }
        model.transport.gestures.record(click: true)
        #expect(Self.code(await Self.send(Self.ask("tests", "gone", option: "allow_once"), model, answerer)) == "refused")
        #expect(answerer.answers.isEmpty)
        #expect(answerer.pending["local/tests p1"] != nil, "the ask still waits for its own answer")
    }

    /// The pane's own chat (its card answers it), a chat another computer's daemon holds, a pane
    /// on another machine, and a chat on another daemon are not this op's: `unsupported`, so the
    /// page opens the chat, and nothing is read or answered.
    @Test func otherChatsOnThisPanesOwnAcpmuxOnly() async {
        let (own, answerer, _) = Self.home(chat: "tests")
        own.transport.gestures.record(click: true)
        #expect(Self.code(await Self.send(Self.ask(option: "allow_once"), own, answerer)) == "unsupported", "the chat itself")
        #expect(Self.code(await Self.send(Self.ask("local/tests", "p1", option: "allow_once"), own, answerer)) == "unsupported")
        let (home, _, _) = Self.home()
        home.transport.gestures.record(click: true)
        #expect(Self.code(await Self.send(Self.ask("build-box/tests", "p1", option: "allow_once"), home, answerer)) == "unsupported", "a peer's chat")
        home.remoteChat = true
        #expect(Self.code(await Self.send(Self.ask(option: "allow_once"), home, answerer)) == "unsupported", "another machine's pane")
        let (elsewhere, _, _) = Self.home(socket: "/tmp/acpmux-chief.sock")
        elsewhere.transport.acpmuxSocket = Self.socket
        elsewhere.transport.gestures.record(click: true)
        #expect(Self.code(await Self.send(Self.ask(option: "allow_once"), elsewhere, answerer)) == "unsupported", "another daemon")
        #expect(answerer.reads.isEmpty && answerer.answers.isEmpty)
    }

    /// The op takes exactly a chat, an ask and an option.
    @Test func theRequestIsExactlyThreeIds() {
        let valid: [String: Any] = ["sessionId": "tests", "permissionId": "p1", "optionId": "allow_once"]
        #expect(AgentPaneRequest(body: ["method": "chat.asks.answer", "params": valid]) == .asksAnswer(Self.ask(option: "allow_once")))
        for params in [
            valid.merging(["answers": [String: Any]()]) { $1 },
            valid.filter { $0.key != "optionId" },
            valid.merging(["permissionId": ""]) { $1 },
            valid.merging(["sessionId": String(repeating: "a", count: 257)]) { $1 },
            valid.merging(["optionId": 1]) { $1 },
        ] {
            #expect(AgentPaneRequest(body: ["method": "chat.asks.answer", "params": params]) == .unsupported("chat.asks.answer"))
        }
    }
}
