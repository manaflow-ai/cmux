import CmuxHomeCoreTestSupport
import Foundation
import os
import Testing
@testable import CmuxHomeCore

/// `WireHomeSource` against a scripted `cmux.wire/1` server (fake HTTP and
/// sockets, a manual clock): the iOS app's DMs and group chats with no daemon
/// (plans/cmux-next/dm-group-chat-DESIGN.md sections 4.3 and 4.5).
@MainActor @Suite struct WireHomeSourceTests {
    let http = FakeWireHTTP()
    let sockets = FakeWireSockets()
    let clock = ManualClock()
    let conversation = WireFixture.conversation
    let userPath = "/v1/wire/user"
    let conversationPath = "/v1/wire/conv/\(WireFixture.conversationID)"

    private func makeSource(auth: HomeWireAuth = .tailscale) -> WireHomeSource {
        WireHomeSource(baseURL: URL(string: "http://mini.tail1234.ts.net:7320")!, auth: auth, displayName: "Me",
                       http: http, sockets: sockets, clock: clock,
                       fetchDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("wire-\(UUID().uuidString)"))
    }

    /// Starts the source and brings its inbox stream online: welcome, subscribe, snapshot, `inbox.list`.
    private func connect(_ source: WireHomeSource) async throws -> WireEventLog {
        let log = WireEventLog(await source.events())
        await waitUntil { !sockets.dialed(userPath).isEmpty }
        let user = try #require(sockets.dialed(userPath).first)
        user.push(WireFixture.welcome())
        await waitUntil { user.sent.contains { $0["t"] == "subscribe" } }
        user.push(["t": "snapshot", "stream": .string("inbox:\(WireFixture.me)"), "seq": 1, "state": [:]])
        await waitUntil { log.sawOnlineInbox }
        return log
    }

    /// Opens the DM on screen and lets its socket take the owner's snapshot (stream seq 3).
    private func open(_ source: WireHomeSource) async throws -> FakeWireSocket {
        _ = try await source.snapshot(of: conversation, tail: 50)
        await waitUntil { !sockets.dialed(conversationPath).isEmpty }
        let socket = try #require(sockets.dialed(conversationPath).first)
        socket.push(WireFixture.welcome())
        await waitUntil { socket.sent.contains { $0["t"] == "subscribe" } }
        socket.push(WireFixture.snapshot(seq: 3, rev: 3, messages: [WireFixture.message(seq: 1)]))
        return socket
    }

    /// Moves the manual clock a second at a time until `condition` holds (a backoff ran out).
    private func advanceUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<200 where !condition() {
            clock.advance(by: .seconds(1))
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(condition())
    }

    @Test func aResendAfterALostAnswerKeepsTheSameKey() async throws {
        let source = makeSource()
        let log = try await connect(source)
        defer { log.stop() }
        let lost = LostOnce()
        http.script { path, _ in
            if path == "/v1/ops", lost.take() { throw URLError(.networkConnectionLost) }
            return nil
        }
        let intent = HomeIntent(op: .sendMessage(conversation: conversation, parts: [.text("hi", mentions: [])]))
        await #expect(throws: HomeRejection.indeterminate) { _ = try await source.submit(intent) }
        _ = try await source.submit(intent)

        let sends = http.ops("message.send")
        #expect(sends.count == 2)
        for body in sends {
            #expect(body["idempotency_key"].string == intent.key.rawValue)
            #expect(body["params"]["client_msg_id"].string == intent.key.rawValue)
            #expect(body["params"]["conversation"].string == WireFixture.conversationID)
            #expect(body["origin"].string == "user")
        }
        await source.shutdown()
    }

    @Test func anEventFromAnotherMemberArrives() async throws {
        let source = makeSource()
        let log = try await connect(source)
        defer { log.stop() }
        let socket = try await open(source)
        socket.push(WireFixture.event(seq: 4, op: "message.send", head: WireFixture.head(rev: 4, lastSeq: 2),
                                      messages: [WireFixture.message(seq: 2, text: "hi from Bob")]))
        await waitUntil { log.messages.contains { $0.message.seq == 2 } }
        let arrived = try #require(log.messages.first { $0.message.seq == 2 })
        #expect(arrived.message.author == ParticipantID(WireFixture.bob))
        #expect(arrived.message.plainText == "hi from Bob")
        #expect(arrived.rev == 4)
        await source.shutdown()
    }

    @Test func aDropResumesAfterTheLastSeq() async throws {
        let source = makeSource()
        let log = try await connect(source)
        defer { log.stop() }
        let first = try await open(source)
        first.push(WireFixture.event(seq: 4, op: "message.send", head: WireFixture.head(rev: 4, lastSeq: 2),
                                     messages: [WireFixture.message(seq: 2)]))
        await waitUntil { log.messages.contains { $0.message.seq == 2 } }

        first.drop()
        await advanceUntil { sockets.dialed(conversationPath).count == 2 }
        let second = try #require(sockets.dialed(conversationPath).dropFirst().first)
        second.push(WireFixture.welcome())
        await waitUntil { second.sent.contains { $0["t"] == "subscribe" } }
        let subscribe = try #require(second.sent.first { $0["t"] == "subscribe" })
        #expect(subscribe["after_seq"].uint == 4)

        // The replay continues the stream: the next seq applies, a repeat does not.
        second.push(WireFixture.event(seq: 4, op: "message.send", head: WireFixture.head(rev: 4, lastSeq: 2),
                                      messages: [WireFixture.message(seq: 2)]))
        second.push(WireFixture.event(seq: 5, op: "message.send", head: WireFixture.head(rev: 5, lastSeq: 3),
                                      messages: [WireFixture.message(seq: 3)]))
        await waitUntil { log.messages.contains { $0.message.seq == 3 } }
        #expect(log.messages.filter { $0.message.seq == 2 }.count == 1)
        await source.shutdown()
    }

    @Test func aGapAsksForASnapshot() async throws {
        let source = makeSource()
        let log = try await connect(source)
        defer { log.stop() }
        let socket = try await open(source)
        socket.push(WireFixture.event(seq: 6, op: "message.send", head: WireFixture.head(rev: 6, lastSeq: 4),
                                      messages: [WireFixture.message(seq: 4)]))
        await waitUntil { socket.sent.contains { $0["t"] == "snapshot.request" } }
        #expect(!log.messages.contains { $0.message.seq == 4 }, "an event after a gap waits for the snapshot")
        socket.push(WireFixture.snapshot(seq: 6, rev: 6, messages: [WireFixture.message(seq: 4)]))
        await waitUntil {
            log.events.contains { if case .conversationPage(let page) = $0 { page.messages.last?.seq == 4 } else { false } }
        }
        await source.shutdown()
    }

    @Test func aTapbackGoesOutAndComesBack() async throws {
        let source = makeSource()
        let log = try await connect(source)
        defer { log.stop() }
        let socket = try await open(source)
        let result = try await source.submit(HomeIntent(op: .addReaction(message: MessageID("msg_1"), conversation: conversation,
                                                                         reaction: .tapback(.love), partIndex: 0)))
        let body = try #require(http.ops("reaction.add").first)
        #expect(body["params"]["message_id"].string == "msg_1")
        #expect(body["params"]["part_index"].int == 0)
        #expect(body["params"]["reaction"]["tapback"].string == "love")
        #expect(result.rev > 0, "the result names the head's revision")

        // Bob's tapback on the same message.
        let reacted = WireFixture.message(seq: 1, reactions: [["author": .string(WireFixture.bob), "part_index": 0,
                                                                "kind": ["tapback": "like"], "at": "2026-10-20T10:00:01.000Z"]])
        socket.push(WireFixture.event(seq: 4, op: "reaction.add", head: WireFixture.head(rev: 4, lastSeq: 1), messages: [reacted]))
        await waitUntil { log.messages.contains { !$0.message.reactions.isEmpty } }
        let message = try #require(log.messages.last?.message)
        #expect(message.reactions == [Reaction(author: ParticipantID(WireFixture.bob), partIndex: 0, kind: .tapback(.like))])
        await source.shutdown()
    }

    @Test func theReadCursorGoesOutAndComesBack() async throws {
        let source = makeSource()
        let log = try await connect(source)
        defer { log.stop() }
        let socket = try await open(source)
        _ = try await source.submit(HomeIntent(op: .setReadCursor(conversation: conversation, seq: 1)))
        let body = try #require(http.ops("read_cursor.set").first)
        #expect(body["params"]["seq"].uint == 1)
        #expect(body["params"]["conversation"].string == WireFixture.conversationID)

        socket.push(WireFixture.event(seq: 4, op: "read_cursor.set", head: WireFixture.head(rev: 4, lastSeq: 1, cursors: [WireFixture.bob: 1])))
        await waitUntil { !log.changes(on: .conversation(conversation)).isEmpty }
        let change = try #require(log.changes(on: .conversation(conversation)).last)
        #expect(change.summary.readCursors[ParticipantID(WireFixture.bob)] == 1)
        #expect(change.rev == 4)
        await source.shutdown()
    }

    @Test func selfHostedSendsNoAuthorizationHeader() async throws {
        let source = makeSource(auth: .tailscale)
        let log = try await connect(source)
        defer { log.stop() }
        _ = try await open(source)
        _ = try await source.submit(HomeIntent(op: .setReadCursor(conversation: conversation, seq: 1)))

        #expect(http.requests.contains { $0.url?.path == "/v1/selfhost/info" })
        #expect(await source.me?.id == ParticipantID(WireFixture.me))
        #expect(!http.requests.isEmpty)
        for request in http.requests { #expect(request.value(forHTTPHeaderField: "Authorization") == nil, "\(request)") }
        for socket in sockets.all {
            #expect(socket.request.value(forHTTPHeaderField: "Authorization") == nil)
            #expect(socket.request.value(forHTTPHeaderField: "Sec-WebSocket-Protocol") == "cmux.wire.v1")
            #expect(socket.request.url?.scheme == "ws")
        }
        await source.shutdown()
    }

    @Test func hostedSendsTheStackBearer() async throws {
        let source = makeSource(auth: .stack(FakeBearer()))
        let log = try await connect(source)
        defer { log.stop() }
        #expect(!http.requests.contains { $0.url?.path == "/v1/selfhost/info" })
        for request in http.requests {
            #expect(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer token-") == true)
        }
        #expect(sockets.all.allSatisfy { $0.request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true })
        #expect(await source.me?.id == ParticipantID(WireFixture.me), "the welcome names the user")
        await source.shutdown()
    }

    @Test func anExpiredTokenCloseAsksForANewToken() async throws {
        let bearer = FakeBearer()
        let source = makeSource(auth: .stack(bearer))
        let log = try await connect(source)
        defer { log.stop() }
        try #require(sockets.dialed(userPath).first).drop(code: 4401)
        await advanceUntil { sockets.dialed(userPath).count == 2 }
        #expect(bearer.refreshes == 1)
        await source.shutdown()
    }

    @Test func theStoreListsTheDMAndSettlesASend() async throws {
        let source = makeSource()
        let store = HomeStore(source: source, blobCacheDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent("wire-blobs-\(UUID().uuidString)"))
        store.start()
        defer { store.stop() }
        await waitUntil { !sockets.dialed(userPath).isEmpty }
        let user = try #require(sockets.dialed(userPath).first)
        user.push(WireFixture.welcome())
        await waitUntil { user.sent.contains { $0["t"] == "subscribe" } }
        user.push(["t": "snapshot", "stream": .string("inbox:\(WireFixture.me)"), "seq": 1, "state": [:]])
        // The inbox entry names only the peer's id; the head read names Bob.
        await waitUntil { store.rows.first { $0.id == conversation }?.title == "Bob" && store.isOnline }
        #expect(store.me?.id == ParticipantID(WireFixture.me))

        http.script { path, body in
            guard path == "/v1/ops", body["op"] == "message.send" else { return nil }
            return HomeWireHTTPReply(json: ["ok": true, "value": ["rev": 4, "seq": 2]])
        }
        await store.open(conversation)
        await waitUntil { !sockets.dialed(conversationPath).isEmpty }
        let socket = try #require(sockets.dialed(conversationPath).first)
        socket.push(WireFixture.welcome())
        await waitUntil { socket.sent.contains { $0["t"] == "subscribe" } }
        socket.push(WireFixture.snapshot(seq: 3, rev: 3, messages: [WireFixture.message(seq: 1)]))

        let key = IdempotencyKey.make()
        _ = try await store.perform(.sendMessage(conversation: conversation, parts: [.text("on the wire", mentions: [])]), key: key)
        var echo = WireFixture.message(seq: 2, author: WireFixture.me, text: "on the wire")
        if case .object(var fields) = echo {
            fields["client_msg_id"] = .string(key.rawValue)
            echo = .object(fields)
        }
        socket.push(WireFixture.event(seq: 4, op: "message.send", actor: WireFixture.me, head: WireFixture.head(rev: 4, lastSeq: 2),
                                      messages: [echo]))
        await waitUntil { store.log.entries.isEmpty }
        await source.shutdown()
    }

    @Test func anAttachmentUploadsThroughTheWorkerAndDownloads() async throws {
        let source = makeSource()
        let log = try await connect(source)
        defer { log.stop() }
        let bytes = Data("a small file".utf8)
        let base = "http://mini.tail1234.ts.net:7320"
        http.script { path, _ in
            switch path {
            case "/v1/home/attachments/intent":
                return HomeWireHTTPReply(json: ["ok": true, "value": [
                    "state": "upload", "mode": "stream", "method": "PUT",
                    "upload_url": .string("\(base)/v1/home/attachments/upload/\(WireFixture.conversationID)/slot.k1.mac"),
                    "headers": ["content-length": .string(String(bytes.count))],
                ]])
            case "/v1/home/attachments/upload/\(WireFixture.conversationID)/slot.k1.mac":
                return HomeWireHTTPReply(json: ["ok": true, "value": ["state": "stored"]])
            case "/v1/home/attachments/url":
                return HomeWireHTTPReply(json: ["ok": true, "value": ["url": .string("\(base)/v1/home/attachments/\(WireFixture.conversationID)/obj1")]])
            case "/v1/home/attachments/\(WireFixture.conversationID)/obj1":
                return HomeWireHTTPReply(status: 200, body: bytes)
            default:
                return nil
            }
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("wire-upload-\(UUID().uuidString).txt")
        try bytes.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let ref = AttachmentRef(hash: String(repeating: "ab", count: 32), name: "note.txt", mimeType: "text/plain", byteCount: bytes.count)
        let stored = try await source.upload(AttachmentUpload(conversation: conversation, fileURL: file, ref: ref))
        #expect(stored == ref)
        let intent = try #require(http.bodies("/v1/home/attachments/intent").first)
        #expect(intent["sha256"].string == ref.hash)
        #expect(intent["byte_count"].int == bytes.count)
        let put = try #require(http.requests.first { $0.httpMethod == "PUT" })
        #expect(put.httpBody == bytes)

        let fetched = try await source.fetch(ref, at: AttachmentLocation(conversation: conversation, message: MessageID("msg_1"), partIndex: 0),
                                             variant: .original)
        #expect(try Data(contentsOf: fetched) == bytes)
        let asked = try #require(http.bodies("/v1/home/attachments/url").first)
        #expect(asked["message_id"].string == "msg_1")
        #expect(asked["part_index"].int == 0)
        await source.shutdown()
    }

    @Test func anAttachmentUploadsOrderedMultipartPiecesBeforeCompletion() async throws {
        let source = makeSource()
        let log = try await connect(source)
        defer { log.stop() }
        let bytes = Data("elevenbytes".utf8)
        let path = "/v1/home/attachments/multipart/\(WireFixture.conversationID)/slot.k1.mac"
        http.script { [http] route, _ in
            switch route {
            case "/v1/home/attachments/intent":
                return HomeWireHTTPReply(json: ["ok": true, "value": [
                    "state": "upload", "mode": "multipart", "method": "PUT", "part_size": 4, "slot": "slot",
                    "upload_url": .string("http://mini.tail1234.ts.net:7320\(path)"),
                ]])
            case path:
                let request = try #require(http.requests.last)
                let number = try #require(request.value(forHTTPHeaderField: "x-cmux-part-number").flatMap(Int.init))
                return HomeWireHTTPReply(json: ["ok": true, "value": [
                    "part_number": .number(Double(number)), "byte_count": .number(Double(request.httpBody?.count ?? 0)),
                    "etag": .string("etag-\(number)"),
                ]])
            case "/v1/home/attachments/multipart/complete":
                return HomeWireHTTPReply(json: ["ok": true, "value": ["state": "stored"]])
            default: return nil
            }
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("wire-multipart-\(UUID().uuidString)")
        try bytes.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let ref = AttachmentRef(hash: String(repeating: "ab", count: 32), name: "note.txt", mimeType: "text/plain", byteCount: bytes.count)
        #expect(try await source.upload(AttachmentUpload(conversation: conversation, fileURL: file, ref: ref)) == ref)
        let puts = http.requests.filter { $0.httpMethod == "PUT" }
        #expect(puts.map { $0.httpBody?.count } == [4, 4, 3])
        #expect(puts.reduce(into: Data()) { $0.append($1.httpBody ?? Data()) } == bytes)
        let complete = try #require(http.bodies("/v1/home/attachments/multipart/complete").first)
        #expect(complete["parts"].array?.map { $0["etag"].string } == ["etag-1", "etag-2", "etag-3"])
        #expect(http.bodies("/v1/home/attachments/intent").first?["multipart"].bool == true)
        #expect(http.requests.last?.url?.path == "/v1/home/attachments/multipart/complete")
        await source.shutdown()
    }

    @Test func theBackoffGrowsToThirtySeconds() {
        #expect((0..<7).map { reconnectDelay(attempt: $0) } == [1, 2, 4, 8, 16, 30, 30].map { Duration.seconds($0) })
    }
}

/// True the first time only.
private final class LostOnce: Sendable {
    // A test fake: a one-shot flag read from the fake server's handler.
    private let taken = OSAllocatedUnfairLock(initialState: false)

    func take() -> Bool {
        taken.withLock { taken in
            defer { taken = true }
            return !taken
        }
    }
}
