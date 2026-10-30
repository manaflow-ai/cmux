import CmuxConversationCore
import Foundation
import Testing
@testable import CmuxMobileChief
@testable import CmuxMobileTransport

/// A clock whose sleeps return at once: backoff waits in tests take no time.
struct ImmediateClock: Clock {
    typealias Duration = Swift.Duration
    struct Instant: InstantProtocol {
        var offset: Swift.Duration
        func advanced(by duration: Swift.Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Swift.Duration { other.offset - offset }
        static func < (a: Instant, b: Instant) -> Bool { a.offset < b.offset }
    }
    var now: Instant { Instant(offset: .zero) }
    var minimumResolution: Swift.Duration { .zero }
    func sleep(until deadline: Instant, tolerance: Swift.Duration?) async throws { try Task.checkCancellation() }
}

/// The text the user's phone showed at 14:31 on 2026-10-14 (the brain's
/// note around Claude Code's error, with the gateway's address).
let gatewayOutage = "(turn failed on claude: API Error: 503 no non-exhausted claude accounts available, next account frees up in 50m (retry after 2945s). This is a server-side issue, usually temporary. Try again in a moment. If it persists, check your inference gateway (100.89.225.106:31415).)"

@Suite struct ChiefTurnFailureTests {
    @Test func gatewayErrorReadsPlainWithNoAddress() throws {
        let failure = try #require(ChiefTurnFailure(text: gatewayOutage))
        #expect(failure.kind == .modelBusy)
        #expect(failure.reply.isEmpty)
        #expect(failure.detail.hasPrefix("API Error: 503"))
        #expect(failure.detail.contains("100.89.225.106:31415"))
        for shown in [failure.displayText, failure.barTitle, failure.modelStatus ?? ""] {
            #expect(!shown.contains("100.89"))
            #expect(!shown.contains("31415"))
            #expect(!shown.lowercased().contains("inference"))
            #expect(!shown.lowercased().contains("api error"))
        }
    }

    @Test func kindsOfModelErrors() {
        let cases: [(String, ChiefTurnFailure.Kind)] = [
            ("API Error: 502 Bad Gateway. This is a server-side issue, usually temporary — try again in a moment. If it persists, check your inference gateway (cmux-lawrences-mac-mini.tail137216.ts.net:31415).", .modelUnreachable),
            ("API Error: Connection error. (ECONNREFUSED 127.0.0.1:1)", .modelUnreachable),
            ("fetch failed", .modelUnreachable),
            ("Repeated 529 Overloaded errors. The API is at capacity — this is usually temporary. Try again in a moment.", .modelBusy),
            ("API Error: 429 rate limit exceeded", .modelBusy),
            ("API Error: 401 {\"type\":\"authentication_error\"}", .modelSignIn),
            ("the harness exited with status 2", .other),
            // A port is not a status code.
            ("harness crashed at 10.0.0.4:14290", .other),
        ]
        for (detail, kind) in cases {
            #expect(ChiefTurnFailure.kind(of: detail) == kind, "\(detail)")
        }
    }

    @Test func keepsTheReplyAndReadsEveryHeader() throws {
        let withReply = try #require(ChiefTurnFailure(text: "Let me check.\n\n(turn failed on claude (fallback for codex): fetch failed)"))
        #expect(withReply.reply == "Let me check.")
        #expect(withReply.kind == .modelUnreachable)
        #expect(withReply.detail == "fetch failed")
        #expect(withReply.displayText.hasPrefix("Let me check.\n\n"))
        let bare = try #require(ChiefTurnFailure(text: "(turn failed: ECONNREFUSED)"))
        #expect(bare.kind == .modelUnreachable)
    }

    /// QA 2026-10-27 (live, rig Mac without Claude): a turn the brain refused
    /// before it ran showed as Chief's reply in operator words (harness kinds,
    /// CLI commands). It reads as a plain sentence now, like a failed turn.
    @Test func aRefusedTurnReadsAsPlainWords() throws {
        let live = "(turn refused: the Chief runs Claude only through acpmux's own Claude Code adapter (kind claude-stdio), and claude asks for one running `claude`; acpmux has none: acpmux has no harness named claude. Fix the acpmux harness (`acpmux daemon harnesses` lists them) and send the message again.)"
        let refused = try #require(ChiefTurnFailure(text: live))
        #expect(refused.reply.isEmpty)
        #expect(refused.detail.hasPrefix("the Chief runs Claude only"))
        #expect(!refused.displayText.contains("acpmux"))
        #expect(ChiefTurnFailure(text: "(turn refused)")?.detail == "refused")
    }

    /// The Mac's Home list cuts previews short (no closing parenthesis).
    @Test func homeRowPreviewsReadAsPlainWords() {
        let cut = "(turn refused: the Chief runs Claude only through acpmux's own Claude Code adapter (kind claude-stdio), and claude asks for one running"
        #expect(ChiefTurnFailure.previewText(cut) == "Chief couldn't finish this reply.")
        #expect(ChiefTurnFailure.previewText("Done.\n\n(turn failed: ECONNREFUSED to 10.0.0.1:443") .hasPrefix("Done.\n\nChief couldn't reach its model"))
        #expect(ChiefTurnFailure.previewText("All 12 tests pass.") == "All 12 tests pass.")
    }

    @Test func leavesOtherMessagesAlone() {
        #expect(ChiefTurnFailure(text: "All 12 tests pass.") == nil)
        #expect(ChiefTurnFailure(text: "(turn stopped)") == nil)
        #expect(ChiefTurnFailure(text: "Done.\n\n(turn stopped)") == nil)
        // Mentioning a failure mid-reply is not the brain's note.
        #expect(ChiefTurnFailure(text: "The CI said (turn failed: x) yesterday, I fixed it.") == nil)
    }

    @Test func onlyChiefsMessagesAreRewritten() throws {
        let wire = ChiefWire(identity: .standard)
        func object(_ author: String, _ text: String) -> [String: Any] {
            ["id": "m1", "seq": 3, "author": author, "parts": [["type": "text", "text": text]], "created_at": "2026-10-14T21:31:00.000Z"]
        }
        let chief = try #require(wire.message(object(ChiefIdentity.standard.chiefID, gatewayOutage), peerReadSeq: 0))
        #expect(chief.text == "Chief's model is busy.")
        #expect(wire.failure(object(ChiefIdentity.standard.chiefID, gatewayOutage))?.detail.contains("31415") == true)
        let mine = try #require(wire.message(object(ChiefIdentity.standard.meID, gatewayOutage), peerReadSeq: 0))
        #expect(mine.text == gatewayOutage)
        #expect(wire.failure(object(ChiefIdentity.standard.meID, gatewayOutage)) == nil)
    }
}

@Suite struct ChiefEngineProblemTests {
    func refusal(_ reason: String, _ message: String) -> ChiefControlError {
        ChiefControlError(code: "operation.failed", reason: reason, message: message)
    }

    @Test func tellsALinkDownFromAChiefThatDidNotAnswer() {
        // No answer from the Mac at all: the link, not Chief.
        #expect(ChiefEngineProblem(LinkError(code: "closed", message: "daemon channel closed")) == .macUnreachable)
        #expect(ChiefEngineProblem(LinkError(code: DaemonClient.replyTimeout, message: "")) == .macUnreachable)
        // The Mac answered for Chief after its 10 s wait.
        #expect(ChiefEngineProblem(refusal("unavailable", "Resource temporarily unavailable (os error 35)")) == .chiefBusy)
        // The Mac answered: Chief's socket is not there.
        if case .chiefDown = ChiefEngineProblem(refusal("unavailable", "No such file or directory (os error 2)")) {} else {
            Issue.record("a missing tools socket is Chief down")
        }
        if case .refused = ChiefEngineProblem(refusal("not_configured", "")) {} else { Issue.record("not configured is a refusal") }
        #expect(ChiefEngineProblem(refusal("internal", "expected value")) == .failed)
        #expect(!ChiefEngineProblem(refusal("not_configured", "")).isTransient)
        #expect(ChiefEngineProblem(LinkError(code: "closed", message: "")).isTransient)
        // The old copy blamed Chief for any of these.
        for problem in [ChiefEngineProblem.macUnreachable, .chiefBusy, .modelsUnavailable] {
            #expect(!problem.loadText.contains("didn't answer. Try again"))
        }
    }

    @Test func aReplyDeadlineEndsAWaitOnAQuietLink() async throws {
        // A link that never answers: the request ends, it does not hang.
        let link = MockMacLink { _, _ in [] }
        let client = DaemonClient(channel: try await link.openChannel(service: "chief", args: [:]))
        do {
            _ = try await client.resourceRequest("chief.engine.get", deadline: .seconds(20), clock: ImmediateClock())
            Issue.record("expected a timeout")
        } catch let error as LinkError {
            #expect(error.code == DaemonClient.replyTimeout)
        }
    }
}

/// A Mac whose Chief control answers from a script: each `chief.engine.get`
/// takes the next reply (the last one repeats); conversation commands go to
/// a ``FakeDaemon``.
final class ScriptedChiefMac: @unchecked Sendable {
    let daemon = FakeDaemon()
    private let lock = NSLock()
    private var replies: [(ok: Bool, body: [String: Any])]
    private(set) var engineReads = 0

    init(_ replies: [(ok: Bool, body: [String: Any])]) {
        self.replies = replies
    }

    static var report: [String: Any] { [
        "engine": ["harness": "claude", "model": "opus", "effort": "high"],
        "choice": ["model": "opus"],
        "offered": ["models": [["id": "opus", "name": "Opus"], ["id": "sonnet", "name": "Sonnet"]], "efforts": ["high"]],
    ] }
    static var busy: [String: Any] { [
        "code": "operation.failed", "message": "unavailable",
        "details": ["operation": "chief.engine.get", "reason": "unavailable", "extra": ["message": "Resource temporarily unavailable (os error 35)"]],
    ] }

    func respond(_ request: Data) -> [Data] {
        let object = (try? JSONSerialization.jsonObject(with: request.dropLast()) as? [String: Any]) ?? [:]
        guard object["operation"] is String, let id = object["id"] as? String else {
            return daemon.respond(request)
        }
        let reply: (ok: Bool, body: [String: Any]) = lock.withLock {
            engineReads += 1
            return replies.count > 1 ? replies.removeFirst() : replies[0]
        }
        var line: [String: Any] = ["protocol": "cmux.protocol/2", "type": "response", "id": id, "ok": reply.ok]
        line[reply.ok ? "result" : "error"] = reply.body
        return [daemon.line(line)]
    }
}

@Suite @MainActor struct ChiefEngineRecoveryTests {
    func defaults() -> UserDefaults {
        let name = "chief-engine-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func session(_ mac: ScriptedChiefMac, preferences: ChiefPreferences, macID: String?) async throws -> ChiefSession {
        let link = MockMacLink { _, request in mac.respond(request) }
        let client = DaemonClient(channel: try await link.openChannel(service: "chief", args: [:]))
        let session = ChiefSession(backend: ChiefOfflineBackend(), preferences: preferences,
                                   outbox: ChiefOutbox(file: nil), clock: ImmediateClock())
        session.macID = macID
        session.use(ChiefDaemonBackend(client: client, preferences: preferences))
        return session
    }

    @Test func keepsTheLastKnownModelPerMacWhileChiefCantAnswer() async throws {
        let preferences = ChiefPreferences(defaults: defaults())
        // First connection: Chief answers; the report is kept for this Mac.
        let good = try await session(ScriptedChiefMac([(true, ScriptedChiefMac.report)]), preferences: preferences, macID: "mac-1")
        #expect(await good.refreshEngine() == nil)
        #expect(preferences.engineReport(macID: "mac-1")?.engine.model == "opus")

        // Next connection: Chief does not answer. The sheet still has the model.
        let down = try await session(ScriptedChiefMac([(false, ScriptedChiefMac.busy)]), preferences: preferences, macID: "mac-1")
        #expect(down.engineReport?.engine.model == "opus")
        #expect(!down.engineReportIsCurrent)
        #expect(await down.refreshEngine() == .chiefBusy)
        #expect(down.engineReport?.offered.models.map(\.id) == ["opus", "sonnet"])
        #expect(down.engineProblem == .chiefBusy)

        // Another Mac has its own (none yet).
        let other = try await session(ScriptedChiefMac([(false, ScriptedChiefMac.busy)]), preferences: preferences, macID: "mac-2")
        #expect(other.engineReport == nil)
    }

    @Test func aReportWithoutModelsKeepsTheKeptModels() async throws {
        let preferences = ChiefPreferences(defaults: defaults())
        var empty = ScriptedChiefMac.report
        empty["offered"] = ["models": [], "efforts": ["high"]]
        let mac = ScriptedChiefMac([(true, ScriptedChiefMac.report), (true, empty)])
        let session = try await session(mac, preferences: preferences, macID: "mac-1")
        await session.refreshEngine()
        #expect(await session.refreshEngine() == .modelsUnavailable)
        #expect(session.engineReport?.pickableModels.map(\.id) == ["opus", "sonnet"])
        // The kept copy is the full one, not the empty one.
        #expect(preferences.engineReport(macID: "mac-1")?.pickableModels.count == 2)
    }

    @Test func watchingRetriesWithBackoffUntilChiefAnswers() async throws {
        let mac = ScriptedChiefMac([(false, ScriptedChiefMac.busy), (false, ScriptedChiefMac.busy), (true, ScriptedChiefMac.report)])
        let session = try await session(mac, preferences: ChiefPreferences(defaults: defaults()), macID: "mac-1")
        await session.watchEngine()
        #expect(session.engineProblem == nil)
        #expect(session.engineReportIsCurrent)
        #expect(session.engineReport?.engine.model == "opus")
        // use() reads once on its own; the watch read three times.
        #expect(mac.engineReads >= 3)
        #expect(ChiefSession.retryDelay(attempt: 0) == .seconds(2))
        #expect(ChiefSession.retryDelay(attempt: 3) == .seconds(16))
        #expect(ChiefSession.retryDelay(attempt: 9) == .seconds(30))
    }

    @Test func watchingStopsOnARefusal() async throws {
        let refused: [String: Any] = ["code": "operation.failed", "message": "not_configured",
                                      "details": ["reason": "not_configured"]]
        let mac = ScriptedChiefMac([(false, refused)])
        let session = try await session(mac, preferences: ChiefPreferences(defaults: defaults()), macID: nil)
        await session.watchEngine()
        if case .refused = session.engineProblem {} else { Issue.record("expected a refusal, got \(String(describing: session.engineProblem))") }
    }

    @Test func tryAgainWithoutAnOriginalMessageSendsNothing() async throws {
        let mac = ScriptedChiefMac([(true, ScriptedChiefMac.report)])
        let session = try await session(mac, preferences: ChiefPreferences(defaults: defaults()), macID: "mac-1")
        try await waitUntil("Chief to connect") { session.isConnected }
        mac.daemon.queueChiefMessage(gatewayOutage)
        _ = try await session.backend.history(beforeSeq: nil, limit: 50)
        try await waitUntil("failed turn") { session.lastTurnFailure != nil }
        session.retryFailedTurn()
        #expect(session.store.messages.allSatisfy { $0.senderID != session.store.meID })
        #expect(mac.daemon.ops.allSatisfy { $0["kind"] as? String != "message.send" })
        if case .failure? = session.barItem {} else { Issue.record("Retry was consumed without sending") }
    }

    @Test(arguments: ["text", "photo", "photo-only", "file", "file-only"])
    func tryAgainSendsTheMessageTheFailedTurnAnswered(kind: String) async throws {
        let mac = ScriptedChiefMac([(true, ScriptedChiefMac.report)])
        let session = try await session(mac, preferences: ChiefPreferences(defaults: defaults()), macID: "mac-1")
        try await waitUntil("Chief to connect") { session.isConnected }
        let text = kind.hasSuffix("-only") ? "" : "summarize the open PRs"
        let photo = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aDZkAAAAASUVORK5CYII=")!
        let file = Data("a,b\n1,2".utf8)
        session.store.send(text: text,
                           images: kind.hasPrefix("photo") ? [(photo, 1, 1, "image/png")] : [],
                           files: kind.hasPrefix("file") ? [ConversationPendingFile(data: file, name: "table.csv")] : [])
        // The fake Chief answers "On it."; then its next turn fails on the model.
        try await waitUntil("Chief's reply") { session.store.messages.contains(where: { $0.text == "On it." }) }
        mac.daemon.queueChiefMessage(gatewayOutage)
        // Any reply carries the queued event.
        _ = try await (session.backend as! ChiefDaemonBackend).history(beforeSeq: nil, limit: 50)
        try await waitUntil("the failed turn to reach the session") { session.lastTurnFailure != nil }
        let shown = try #require(session.store.messages.last)
        #expect(!shown.text.contains("31415"))
        guard case .failure(_, let failure)? = session.barItem else {
            Issue.record("expected Try Again on the bar")
            return
        }
        #expect(failure.kind == .modelBusy)

        session.retryFailedTurn()
        session.retryFailedTurn() // A second tap must not send another copy.
        try await waitUntil("Try Again to resend") { mac.daemon.ops.filter({ $0["kind"] as? String == "message.send" }).count >= 2 }
        let sends = mac.daemon.ops.filter { $0["kind"] as? String == "message.send" }
        #expect(sends.count == 2)
        let parts = try #require(sends.last?["parts"] as? [[String: Any]])
        let resent = parts.first(where: { $0["type"] as? String == "text" })?["text"] as? String ?? ""
        #expect(resent == text)
        let attachments = parts.filter { $0["type"] as? String == "attachment" }
        #expect(attachments.count == (kind == "text" ? 0 : 1))
        if let attachment = attachments.first {
            let hash = try #require(attachment["hash"] as? String)
            #expect(mac.daemon.stored[hash] == (kind.hasPrefix("photo") ? photo : file))
            if kind.hasPrefix("photo") { #expect(attachment["mime_type"] as? String == "image/png") }
            if kind.hasPrefix("file") { #expect(attachment["name"] as? String == "table.csv") }
        }
        // Once tried again, the bar no longer offers it.
        if case .failure? = session.barItem { Issue.record("Try Again offered twice") }
    }
}
