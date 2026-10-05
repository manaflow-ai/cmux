import Foundation
import Synchronization
import Testing
@testable import CmuxNextDaemon

/// Layer 4 of CLIPBOARD-READ-BROKER, the app's half: the policy, the
/// subscription the app keeps on the daemon connection, and the answers to
/// `terminal-clipboard-read` (cmux-tui/spec/commands.md "Terminal clipboard reads").
@MainActor @Suite(.timeLimit(.minutes(1))) struct TerminalClipboardBrokerTests {
    static let termA = "term_0123456789abcdef0123456789abcdef"
    static let termB = "term_fedcba9876543210fedcba9876543210"

    /// Records what the broker asks of the app and the daemon.
    @MainActor final class Harness {
        var setting: ClipboardReadSetting = .ask
        var pasteboard: String? = "clip"
        var subscribes: [[String]] = []
        var replies: [Reply] = []
        var prompts: [ClipboardReadPrompt] = []
        var answers: [String: @MainActor (Bool) -> Void] = [:]
        var closed: [String] = []
        let host: ClipboardReadHost
        private(set) var broker: TerminalClipboardBroker!

        struct Reply: Equatable {
            var id: String
            var text: String?
        }

        init(host: ClipboardReadHost = ClipboardReadHost(kind: .local)) {
            self.host = host
            broker = TerminalClipboardBroker(host: host, environment: .init(
                setting: { [unowned self] in setting },
                pasteboardText: { [unowned self] _ in pasteboard },
                ask: { [unowned self] prompt, answer in
                    prompts.append(prompt)
                    answers[prompt.requestID] = answer
                    return { [unowned self] in
                        closed.append(prompt.requestID)
                        // A dialog closed by the app answers with its cancel button.
                        answer(false)
                    }
                },
                subscribe: { [unowned self] ids in subscribes.append(ids) },
                reply: { [unowned self] id, text in replies.append(Reply(id: id, text: text)) }))
        }

        /// Connects and subscribes `terminals`.
        func connect(_ terminals: [String] = [TerminalClipboardBrokerTests.termA, TerminalClipboardBrokerTests.termB]) async {
            broker.setConnection(1)
            broker.setTerminals(terminals)
            await settle()
        }

        func settle() async {
            await broker.subscribing?.value
            await broker.lastReply?.value
        }

        func read(_ id: String, terminal: String = TerminalClipboardBrokerTests.termA, location: TerminalClipboardRead.Location = .standard,
                  host: ClipboardReadHost = ClipboardReadHost(kind: .local)) async {
            broker.handle(.terminalClipboardRead(TerminalClipboardRead(requestID: id, terminalID: terminal, location: location, host: host)))
            await settle()
        }
    }

    @MainActor final class SettingBox {
        var value = ClipboardReadSetting.allow
    }

    // MARK: Policy

    @Test func policyAllowsOnlyLocalTerminalsAndDenyAlwaysDenies() {
        #expect(ClipboardReadSetting.allow.decision(host: .local) == .allow)
        #expect(ClipboardReadSetting.allow.decision(host: .remote) == .ask)
        #expect(ClipboardReadSetting.allow.decision(host: .cloud) == .ask)
        for host in [ClipboardReadHostKind.local, .remote, .cloud] {
            #expect(ClipboardReadSetting.deny.decision(host: host) == .deny)
            #expect(ClipboardReadSetting.ask.decision(host: host) == .ask)
        }
    }

    @Test func settingFollowsGhosttyValuesAndDefaultsToAsk() {
        #expect(ClipboardReadSetting(ghosttyValue: "allow") == .allow)
        #expect(ClipboardReadSetting(ghosttyValue: "deny") == .deny)
        #expect(ClipboardReadSetting(ghosttyValue: "ask") == .ask)
        #expect(ClipboardReadSetting(ghosttyValue: nil) == .ask)
        #expect(ClipboardReadSetting(ghosttyValue: "sometimes") == .ask)
    }

    // MARK: Wire

    @Test func readEventsDecodeOnTheConnection() async throws {
        let server = try FakeDaemonServer(handler: ConnectionTests.handshake { _, _ in [] })
        defer { server.stop() }
        let connection = DaemonConnection(endpoint: DaemonEndpoint(socketPath: server.path))
        try await connection.start()
        var iterator = connection.events.makeAsyncIterator()
        guard case .connected? = try await iterator.next()?.event else {
            Issue.record("first event is not .connected")
            return
        }
        server.push(#"{"event":"terminal-clipboard-read","request_id":"r1","terminal_id":"\#(Self.termA)","location":"primary","host":{"kind":"local"}}"#)
        server.push(#"{"event":"terminal-clipboard-read-cancelled","request_id":"r1"}"#)
        let read = try #require(try await iterator.next())
        #expect(read.event == .terminalClipboardRead(TerminalClipboardRead(
            requestID: "r1", terminalID: Self.termA, location: .primary, host: ClipboardReadHost(kind: .local))))
        #expect(read.event.outlivesSnapshot)
        let cancelled = try #require(try await iterator.next())
        #expect(cancelled.event == .terminalClipboardReadCancelled(requestID: "r1"))
        await connection.close()
    }

    @Test func subscriptionAndRepliesReachTheDaemon() async throws {
        let log = PlacementTests.Log()
        let server = try FakeDaemonServer(handler: ConnectionTests.handshake { request, id in
            log.append(request)
            switch request["cmd"]?.stringValue {
            case "terminal-clipboard-subscribe": return [#"{"id":\#(id),"ok":true,"data":{"clipboard_read_ready":true}}"#]
            case "terminal-clipboard-reply": return [#"{"id":\#(id),"ok":true,"data":{"accepted":true,"granted":true}}"#]
            default: return []
            }
        })
        defer { server.stop() }
        let connection = DaemonConnection(endpoint: DaemonEndpoint(socketPath: server.path))
        try await connection.start()
        let setting = SettingBox()
        let broker = TerminalClipboardBroker(host: ClipboardReadHost(kind: .local), environment: .init(
            setting: { setting.value },
            pasteboardText: { _ in "pasted" },
            ask: { _, _ in {} },
            subscribe: { ids in
                let ready = try await connection.request(TerminalClipboardSubscribeRequest(terminalIDs: ids))
                #expect(ready.clipboardReadReady)
            },
            reply: { id, text in _ = try await connection.request(TerminalClipboardReplyRequest(requestID: id, text: text)) }))
        broker.setConnection(1)
        broker.setTerminals([Self.termB, Self.termA, Self.termA])
        await broker.subscribing?.value
        broker.handle(.terminalClipboardRead(TerminalClipboardRead(requestID: "r1", terminalID: Self.termA, location: .standard,
                                                                   host: ClipboardReadHost(kind: .local))))
        setting.value = .deny
        broker.handle(.terminalClipboardRead(TerminalClipboardRead(requestID: "r2", terminalID: Self.termB, location: .standard,
                                                                   host: ClipboardReadHost(kind: .local))))
        await broker.lastReply?.value
        let requests = log.all
        #expect(requests.map { $0["cmd"]?.stringValue ?? "" } == ["terminal-clipboard-subscribe", "terminal-clipboard-reply", "terminal-clipboard-reply"])
        #expect(requests[0]["terminal_ids"] == .array([.string(Self.termA), .string(Self.termB)]))
        #expect(requests[1]["request_id"]?.stringValue == "r1")
        #expect(requests[1]["text"]?.stringValue == "pasted")
        #expect(requests[2]["request_id"]?.stringValue == "r2")
        // A refusal sends no text at all.
        #expect(requests[2]["text"] == nil)
        broker.stop()
        await connection.close()
    }

    // MARK: Subscription

    @Test func resubscribesWhenTheSetChangesAndAfterReconnect() async {
        let harness = Harness()
        await harness.connect([Self.termB, Self.termA])
        harness.broker.setTerminals([Self.termA, Self.termB])
        await harness.settle()
        #expect(harness.subscribes == [[Self.termA, Self.termB]], "an unchanged set sends nothing")
        harness.broker.setTerminals([Self.termA])
        await harness.settle()
        harness.broker.setConnection(nil)
        harness.broker.setTerminals([Self.termA])
        await harness.settle()
        harness.broker.setConnection(2)
        await harness.settle()
        #expect(harness.subscribes == [[Self.termA, Self.termB], [Self.termA], [Self.termA]])
        #expect(harness.broker.subscribedTerminals == [Self.termA])
    }

    @Test func readForATerminalNotSubscribedIsIgnored() async {
        let harness = Harness()
        harness.setting = .allow
        await harness.connect([Self.termA])
        await harness.read("r1", terminal: Self.termB)
        #expect(harness.replies.isEmpty)
        #expect(harness.prompts.isEmpty)
        // Before any connection nothing is answered either.
        let idle = Harness()
        idle.setting = .allow
        await idle.read("r2")
        #expect(idle.replies.isEmpty)
    }

    // MARK: Answers

    @Test func allowRepliesWithThePasteboardAndDenyRefuses() async {
        let harness = Harness()
        await harness.connect()
        harness.setting = .allow
        await harness.read("r1")
        harness.setting = .deny
        await harness.read("r2", terminal: Self.termB)
        harness.setting = .allow
        harness.pasteboard = nil
        await harness.read("r3")
        #expect(harness.replies == [.init(id: "r1", text: "clip"), .init(id: "r2", text: nil), .init(id: "r3", text: nil)])
        #expect(harness.prompts.isEmpty)
    }

    @Test func askAnswersFromTheUser() async {
        let harness = Harness()
        await harness.connect()
        await harness.read("r1", location: .selection)
        #expect(harness.replies.isEmpty)
        #expect(harness.prompts == [ClipboardReadPrompt(requestID: "r1", terminalID: Self.termA, location: .selection,
                                                        host: ClipboardReadHost(kind: .local))])
        #expect(harness.broker.openRequests == ["r1"])
        harness.answers["r1"]?(true)
        await harness.read("r2", terminal: Self.termB)
        harness.answers["r2"]?(false)
        await harness.settle()
        #expect(harness.replies == [.init(id: "r1", text: "clip"), .init(id: "r2", text: nil)])
        #expect(harness.broker.openRequests.isEmpty)
        // A second answer to the same question sends nothing.
        harness.answers["r1"]?(true)
        await harness.settle()
        #expect(harness.replies.count == 2)
    }

    @Test func allowNeverSkipsTheQuestionOffThisMac() async {
        let harness = Harness()
        harness.setting = .allow
        await harness.connect()
        await harness.read("r1", host: ClipboardReadHost(kind: .cloud, name: "vm-1"))
        #expect(harness.replies.isEmpty)
        #expect(harness.prompts.map(\.host) == [ClipboardReadHost(kind: .cloud, name: "vm-1")])
        // Through a remote connection the connection's host is named, even
        // though the daemon calls its terminals local.
        let remote = Harness(host: ClipboardReadHost(kind: .remote, name: "devbox"))
        remote.setting = .allow
        await remote.connect()
        await remote.read("r2")
        #expect(remote.replies.isEmpty)
        #expect(remote.prompts.map(\.host) == [ClipboardReadHost(kind: .remote, name: "devbox")])
    }

    @Test func cancelClosesTheQuestionWithoutAReply() async {
        let harness = Harness()
        await harness.connect()
        await harness.read("r1")
        harness.broker.handle(.terminalClipboardReadCancelled(requestID: "r1"))
        await harness.settle()
        #expect(harness.closed == ["r1"])
        #expect(harness.broker.openRequests.isEmpty)
        harness.answers["r1"]?(true)
        await harness.settle()
        #expect(harness.replies.isEmpty)
    }

    @Test func oneOpenQuestionPerTerminal() async {
        let harness = Harness()
        await harness.connect()
        await harness.read("r1")
        await harness.read("r2")
        #expect(harness.prompts.map(\.requestID) == ["r1"])
        #expect(harness.replies == [.init(id: "r2", text: nil)])
    }

    @Test func disconnectClosesOpenQuestionsWithoutReplies() async {
        let harness = Harness()
        await harness.connect()
        await harness.read("r1")
        harness.broker.setConnection(nil)
        await harness.settle()
        #expect(harness.closed == ["r1"])
        #expect(harness.replies.isEmpty)
    }

    @Test func oversizedTextIsRefused() async {
        let harness = Harness()
        harness.setting = .allow
        harness.pasteboard = String(repeating: "x", count: TerminalClipboardBroker.maxReplyBytes + 1)
        await harness.connect()
        await harness.read("r1")
        #expect(harness.replies == [.init(id: "r1", text: nil)])
    }
}
