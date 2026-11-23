import CmuxMobileAgentChat
import CmuxMobileChief
import Foundation
import Testing
@testable import CmuxMobileLive

/// Auto chats on the phone, at the boundary the Rust client answers through
/// (``AutoChatService``, ``AutoChatLine``): what the list, an open chat and a sent message make
/// of its answers. The requests themselves are tested in Rust (`cmux-mobile-auto`).
@MainActor
@Suite(.timeLimit(.minutes(1))) struct AutoChatsTests {
    /// One open chat, scripted: `next` answers what the test queued, and is held when nothing is.
    final class Line: AutoChatLine, @unchecked Sendable {
        private let lock = NSLock()
        private var answers: [Result<String, AutoChatFailure>] = []
        private var waiter: CheckedContinuation<String, any Error>?
        private var closed = false
        private var sentMessages: [String] = []
        private var keptChoices: [Bool] = []
        private var sendAnswer: Result<String, AutoChatFailure> = .failure(.unreachable)
        private var keepAnswer: Result<String, AutoChatFailure> = .failure(.unreachable)
        /// What a read answers once the reader left.
        private static let left = #"{"chat":null,"records":[],"caughtUp":false,"ended":true,"retryAfterMs":null}"#

        var isClosed: Bool { lock.withLock { closed } }
        /// Every message sent, as `id text`.
        var sent: [String] { lock.withLock { sentMessages } }
        var kept: [Bool] { lock.withLock { keptChoices } }

        func answer(_ result: Result<String, AutoChatFailure>) {
            let waiting = lock.withLock { () -> CheckedContinuation<String, any Error>? in
                guard let waiter else {
                    answers.append(result)
                    return nil
                }
                self.waiter = nil
                return waiter
            }
            waiting?.resume(with: result)
        }

        func answer(_ json: String) { answer(.success(json)) }
        func answersSend(_ result: Result<String, AutoChatFailure>) { lock.withLock { sendAnswer = result } }
        func answersKeep(_ result: Result<String, AutoChatFailure>) { lock.withLock { keepAnswer = result } }

        func next() async throws -> String {
            try await withCheckedThrowingContinuation { continuation in
                let ready = lock.withLock { () -> Result<String, AutoChatFailure>? in
                    if !answers.isEmpty { return answers.removeFirst() }
                    if closed { return .success(Self.left) }
                    waiter = continuation
                    return nil
                }
                if let ready { continuation.resume(with: ready) }
            }
        }

        func send(messageID: String, text: String) async throws -> String {
            try lock.withLock {
                sentMessages.append("\(messageID) \(text)")
                return sendAnswer
            }.get()
        }

        func keep(_ keepInCloud: Bool) async throws -> String {
            try lock.withLock {
                keptChoices.append(keepInCloud)
                return keepAnswer
            }.get()
        }

        func close() {
            let waiting = lock.withLock { () -> CheckedContinuation<String, any Error>? in
                closed = true
                let waiting = waiter
                waiter = nil
                return waiting
            }
            waiting?.resume(returning: Self.left)
        }
    }

    /// The account's Auto chats, scripted.
    final class Service: AutoChatService, @unchecked Sendable {
        private let lock = NSLock()
        private var listAnswer: Result<String, AutoChatFailure> = .success(#"{"chats":[],"repos":[],"more":false}"#)
        private var startAnswer: Result<String, AutoChatFailure> = .failure(.unreachable)
        private var machine = true
        private var startCalls: [String] = []
        private var waiting: [Line] = []
        private var handedOut: [Line] = []

        /// Every chat started, as `remote branch id text`.
        var starts: [String] { lock.withLock { startCalls } }
        /// Every line a reader was given, in order.
        var handed: [Line] { lock.withLock { handedOut } }

        func answersList(_ result: Result<String, AutoChatFailure>) { lock.withLock { listAnswer = result } }
        func answersStart(_ result: Result<String, AutoChatFailure>) { lock.withLock { startAnswer = result } }
        func has(machine: Bool) { lock.withLock { self.machine = machine } }
        /// The next reader gets `line`.
        func hands(_ line: Line) { lock.withLock { waiting.append(line) } }

        func list() async throws -> String { try lock.withLock { listAnswer }.get() }
        func hasMachine() async throws -> Bool { lock.withLock { machine } }

        func start(remote: String, branch: String, messageID: String, text: String) async throws -> String {
            try lock.withLock {
                startCalls.append("\(remote) \(branch) \(messageID) \(text)")
                return startAnswer
            }.get()
        }

        func line(id: String) -> any AutoChatLine {
            lock.withLock {
                let line = waiting.isEmpty ? Line() : waiting.removeFirst()
                handedOut.append(line)
                return line
            }
        }
    }

    /// The rows an open chat reported, in order.
    @MainActor final class Rows {
        var seen: [AutoChatRow] = []
    }

    static let remote = "https://github.com/acme/app.git"

    static func row(_ id: String, place: String = "cloud", title: String = "", keep: Bool = false, inCloud: Bool = true,
                    closed: Bool = false) -> String {
        #"{"id":"\#(id)","title":"\#(title)","harness":"claude","place":"\#(place)","keepInCloud":\#(keep),"inCloud":\#(inCloud),"repo":{"remote":"\#(remote)","branch":"main"},"updatedAt":1,"closed":\#(closed)}"#
    }

    static func batch(chat: String? = nil, records: [String] = [], caughtUp: Bool = false, ended: Bool = false,
                      retryAfterMs: Int? = nil) -> String {
        #"{"chat":\#(chat ?? "null"),"records":[\#(records.joined(separator: ","))],"caughtUp":\#(caughtUp),"ended":\#(ended),"retryAfterMs":\#(retryAfterMs.map(String.init) ?? "null")}"#
    }

    static func record(_ seq: Int, _ kind: String, _ msg: String) -> String {
        #"{"sessionId":"a1","seq":\#(seq),"at":1000,"dir":"mux","kind":"\#(kind)","msg":\#(msg)}"#
    }

    static func parsed(_ json: String) throws -> AutoChatRow {
        try #require(AutoChatRow(JSONValue(jsonData: Data(json.utf8))))
    }

    static func prompt(_ text: String, id: String, attachments: [AgentAttachment] = [], resend: Bool = false) -> AgentClientIntent {
        .prompt(text: text, attachments: attachments, steer: false, promptID: id, resend: resend)
    }

    /// A chat's source with the line its reader gets, and the rows it reports.
    static func source(_ service: Service, place: String = "cloud") throws -> (AutoChatSource, Line, Rows) {
        let line = Line()
        service.hands(line)
        let rows = Rows()
        let source = AutoChatSource(row: try parsed(row("a1", place: place)), service: service) { rows.seen.append($0) }
        return (source, line, rows)
    }

    /// Waits for something a call with no event of its own does (a row that changes back).
    static func eventually(_ holds: @MainActor () -> Bool) async throws -> Bool {
        var end = AwakeDeadline(.seconds(20))
        while !holds(), end.hasTimeLeft() {
            try await Task.sleep(for: .milliseconds(5)) // test: waits for the call's answer to be applied
        }
        return holds()
    }

    // MARK: The list

    @Test func theListShowsTheOpenChatsAndWhereEachIs() async throws {
        let service = Service()
        let chats = [Self.row("a1", title: "Fix login"), Self.row("a2", place: "resuming"),
                     Self.row("a3", place: "on_mac", inCloud: false), Self.row("a4", place: "no_machine", inCloud: false),
                     Self.row("a5", place: "coming_back"), Self.row("a6", closed: true),
                     #"{"id":"a7","place":"a_place_this_build_does_not_know"}"#]
        service.answersList(.success(#"{"chats":[\#(chats.joined(separator: ","))],"repos":[{"remote":"\#(Self.remote)","branch":"main"}],"more":false}"#))
        let model = AutoChatsModel(service: service)
        await model.load()
        #expect(model.phase == .loaded)
        // A chat with Auto switched off, and a row this build cannot read, are not listed.
        #expect(model.chats.map(\.id) == ["a1", "a2", "a3", "a4", "a5"])
        #expect(model.chats.map(\.place) == [.cloud, .resuming, .onMac, .noMachine, .comingBack])
        #expect(model.chats[0].name == "Fix login")
        // A chat with no title yet goes by its repository.
        #expect(model.chats[1].name == "acme/app")
        #expect(model.repos == [AutoChatRepo(remote: Self.remote, branch: "main")])
        // Every place that runs or waits says so in one line; only a chat coming back adds when.
        #expect(model.chats.allSatisfy { $0.place.line != nil })
        #expect(model.chats.filter { $0.place.hint != nil }.map(\.id) == ["a5"])
        #expect(AutoChatPlace.idle.line == nil)
    }

    @Test func aReadThatFailsKeepsTheRowsAlreadyShown() async {
        let service = Service()
        service.answersList(.success(#"{"chats":[\#(Self.row("a1"))],"repos":[],"more":false}"#))
        let model = AutoChatsModel(service: service)
        await model.load()
        service.answersList(.failure(.unreachable))
        await model.load()
        #expect(model.phase == .failed)
        #expect(model.chats.map(\.id) == ["a1"])
        service.answersList(.success("not the list"))
        await model.load()
        #expect(model.phase == .failed)
        #expect(model.chats.map(\.id) == ["a1"])
        service.answersList(.success(#"{"chats":[],"repos":[],"more":false}"#))
        await model.load()
        #expect(model.phase == .loaded)
        #expect(model.chats.isEmpty)
    }

    // MARK: An open chat

    @Test func anOpenChatDrawsItsRecordsThenFollowsIt() async throws {
        let service = Service()
        let (source, line, rows) = try Self.source(service)
        line.answer(Self.batch(chat: Self.row("a1", title: "Fix login"),
                               records: [Self.record(1, "user_message", #"{"text":"hi","promptId":"p1","turnId":"t1"}"#)],
                               caughtUp: true))
        var events = source.events().makeAsyncIterator()
        let first = await events.next()
        guard case let .batch(history) = first else {
            Issue.record("the chat's records did not arrive as one batch: \(String(describing: first))")
            return
        }
        #expect(history.contains { event in
            if case let .userMessage(text, promptID, turnID, _, _) = event { return text == "hi" && promptID == "p1" && turnID == "t1" }
            return false
        })
        let caughtUp = await events.next()
        #expect(caughtUp == .historyLoading(false))
        // The chat's own title, once read, is its name in the header and in the list's row.
        #expect(source.summary.name == "Fix login")
        #expect(rows.seen.map(\.title) == ["Fix login"])

        // What arrives later is drawn as it arrives, and the row says where the chat is now.
        line.answer(Self.batch(chat: Self.row("a1", place: "resuming", title: "Fix login"),
                               records: [Self.record(2, "turn_started", #"{"turnId":"t2"}"#)], caughtUp: true))
        let later = await events.next()
        guard case let .batch(live) = later else {
            Issue.record("a later record did not arrive: \(String(describing: later))")
            return
        }
        #expect(live.contains { if case .turnStarted("t2", _) = $0 { true } else { false } })
        #expect(source.row.place == .resuming)
        #expect(rows.seen.last?.place == .resuming)
    }

    @Test func aMessageGoesOutOnceUnderItsPromptsID() async throws {
        let service = Service()
        let (source, line, _) = try Self.source(service)
        line.answer(Self.batch(chat: Self.row("a1"), caughtUp: true))
        var events = source.events().makeAsyncIterator()
        _ = await events.next()

        // Sent: the message shows as waiting, and the chat says "Resuming" until a machine takes it.
        line.answersSend(.success(Self.batch(chat: Self.row("a1", place: "resuming"),
                                             records: [Self.record(0, "queued", #"{"promptId":"m1","text":"go","position":0}"#)])))
        source.send(Self.prompt("go", id: "m1"))
        let queued = await events.next()
        #expect(queued == .batch([.queued(text: "go", promptId: "m1", position: 0)]))
        #expect(source.row.place == .resuming)

        // Not sent: the composer gets the draft back under the same id, and sending it again
        // uses that id, which the Cloud service takes once.
        line.answersSend(.failure(.unreachable))
        source.send(Self.prompt("again", id: "m2"))
        let notSent = await events.next()
        #expect(notSent == .promptNotSent(text: "again", attachments: [], promptID: "m2", reason: AutoChatWords.notSent))
        line.answersSend(.success(Self.batch(chat: Self.row("a1", place: "resuming"),
                                             records: [Self.record(0, "queued", #"{"promptId":"m2","text":"again","position":1}"#)])))
        source.send(Self.prompt("again", id: "m2", resend: true))
        let resent = await events.next()
        #expect(resent == .batch([.queued(text: "again", promptId: "m2", position: 1)]))
        #expect(line.sent == ["m1 go", "m2 again", "m2 again"])
    }

    @Test func onlyATextMessageIsSent() async throws {
        let service = Service()
        let (source, line, _) = try Self.source(service)
        line.answer(Self.batch(chat: Self.row("a1"), caughtUp: true))
        var events = source.events().makeAsyncIterator()
        _ = await events.next()
        let photo = AgentAttachment.recordedImage(id: "i1", name: nil)
        source.send(Self.prompt("look", id: "m1", attachments: [photo]))
        let withPhoto = await events.next()
        #expect(withPhoto == .promptNotSent(text: "look", attachments: [photo], promptID: "m1", reason: AutoChatWords.textOnly))
        // Stop, a permission answer or a model change has no route from a phone to an Auto chat.
        source.send(.cancel)
        let stop = await events.next()
        #expect(stop == .clientError(AutoChatWords.textOnly))
        #expect(line.sent.isEmpty)
    }

    @Test func aReadWithNoAnswerShowsOfflineUntilOneArrives() async throws {
        let service = Service()
        let (source, line, _) = try Self.source(service)
        line.answer(Self.batch(retryAfterMs: 500))
        var events = source.events().makeAsyncIterator()
        let down = await events.next()
        #expect(down == .status(.disconnected))
        #expect(source.isOffline)
        line.answer(Self.batch(chat: Self.row("a1"), caughtUp: true))
        let up = await events.next()
        #expect(up == .status(.ready))
        let caughtUp = await events.next()
        #expect(caughtUp == .historyLoading(false))
        #expect(!source.isOffline)
    }

    @Test func aChatWithAutoSwitchedOffEndsAndTakesNoMessage() async throws {
        let service = Service()
        let (source, line, _) = try Self.source(service)
        line.answer(Self.batch(chat: Self.row("a1", closed: true), ended: true))
        var events = source.events().makeAsyncIterator()
        let loaded = await events.next()
        #expect(loaded == .historyLoading(false))
        let closed = await events.next()
        #expect(closed == .status(.closed))
        #expect(source.ended)
        source.send(Self.prompt("go", id: "m1"))
        let notSent = await events.next()
        #expect(notSent == .promptNotSent(text: "go", attachments: [], promptID: "m1", reason: AutoChatWords.notSent))
        #expect(line.sent.isEmpty)
    }

    @Test func aChatTheServiceRefusesSaysSoAndCloses() async throws {
        let service = Service()
        let (source, line, _) = try Self.source(service)
        line.answer(.failure(.refused(status: 404, code: "session_not_found")))
        var events = source.events().makeAsyncIterator()
        let loaded = await events.next()
        #expect(loaded == .historyLoading(false))
        let said = await events.next()
        #expect(said == .clientError(AutoChatWords.unavailable))
        let closed = await events.next()
        #expect(closed == .status(.closed))
        #expect(source.unavailable)
    }

    @Test func keepInCloudShowsAtOnceAndGoesBackWhenItFails() async throws {
        let service = Service()
        let (source, line, rows) = try Self.source(service)
        line.answer(Self.batch(chat: Self.row("a1"), caughtUp: true))
        var events = source.events().makeAsyncIterator()
        _ = await events.next()

        line.answersKeep(.failure(.unreachable))
        source.keepInCloud(true)
        #expect(source.row.keepInCloud)
        #expect(try await Self.eventually { source.keepFailed })
        #expect(!source.row.keepInCloud)
        #expect(rows.seen.map(\.keepInCloud) == [true, false])

        source.keepFailed = false
        line.answersKeep(.success(Self.batch(chat: Self.row("a1", title: "kept", keep: true))))
        source.keepInCloud(true)
        #expect(try await Self.eventually { source.row.title == "kept" })
        #expect(source.row.keepInCloud)
        #expect(!source.keepFailed)
        #expect(line.kept == [true, true])
    }

    @Test func leavingAChatEndsItsHeldRequest() async throws {
        let service = Service()
        let (source, line, _) = try Self.source(service)
        line.answer(Self.batch(chat: Self.row("a1"), caughtUp: true))
        var events = source.events().makeAsyncIterator()
        _ = await events.next()
        source.close()
        #expect(line.isClosed)
        let end = await events.next()
        #expect(end == nil)
        // A message after that is not sent anywhere.
        source.send(Self.prompt("go", id: "m1"))
        #expect(line.sent.isEmpty)
    }

    @Test func oneChatIsReadAtATime() async throws {
        let service = Service()
        let model = AutoChatsModel(service: service)
        let one = try Self.parsed(Self.row("a1"))
        let two = try Self.parsed(Self.row("a2"))
        let first = model.chat(one)
        #expect(service.handed.count == 1)
        // The same chat again is the same reader, not a second one.
        let again = model.chat(one)
        #expect(again.source === first.source)
        #expect(service.handed.count == 1)
        _ = model.chat(two)
        #expect(service.handed.count == 2)
        #expect(service.handed[0].isClosed)
        #expect(!service.handed[1].isClosed)
        model.leave()
        #expect(service.handed[1].isClosed)
        // Opened again after leaving, it is read anew.
        _ = model.chat(two)
        #expect(service.handed.count == 3)
        model.leave()
    }

    // MARK: A new chat

    @Test func aNewChatStartsInTheChosenRepositoryWithItsFirstMessage() async throws {
        let service = Service()
        let model = AutoChatsModel(service: service)
        let repo = AutoChatRepo(remote: Self.remote, branch: "main")
        service.answersStart(.success(#"{"outcome":"chat","chat":\#(Self.row("a9", place: "resuming"))}"#))
        let started = await model.start(repo: repo, text: "fix the login page", messageID: "m1")
        guard case let .chat(row) = started else {
            Issue.record("the chat did not start: \(started)")
            return
        }
        #expect(row.id == "a9" && row.place == .resuming)
        #expect(service.starts == ["\(Self.remote) main m1 fix the login page"])
        #expect(model.chats.first?.id == "a9")
        #expect(model.hasMachine == true)
        // It opens as starting: its first message is not in the transcript yet.
        #expect(model.chat(row).source.awaitsFirstPrompt)
    }

    @Test func aNewChatWithNoCloudMachineSaysSoAndStartsNothing() async {
        let service = Service()
        let model = AutoChatsModel(service: service)
        let repo = AutoChatRepo(remote: Self.remote, branch: "main")
        service.has(machine: false)
        await model.readMachine()
        #expect(model.hasMachine == false)
        service.answersStart(.success(#"{"outcome":"no_machine"}"#))
        #expect(await model.start(repo: repo, text: "go", messageID: "m1") == .noMachine)
        #expect(model.chats.isEmpty)
        // A start that got no answer, or one the service left half done, is a failure to retry
        // under the same message id.
        service.answersStart(.failure(.unreachable))
        #expect(await model.start(repo: repo, text: "go", messageID: "m1") == .failed)
        service.answersStart(.success(#"{"outcome":"incomplete"}"#))
        #expect(await model.start(repo: repo, text: "go", messageID: "m1") == .failed)
        #expect(service.starts.count == 3)
        #expect(service.starts.allSatisfy { $0.hasSuffix(" m1 go") })
    }
}
