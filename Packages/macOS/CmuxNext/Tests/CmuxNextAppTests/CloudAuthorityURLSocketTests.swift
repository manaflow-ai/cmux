import Foundation
import Testing
@testable import CmuxNextCloud

@Suite(.timeLimit(.minutes(1))) struct CloudAuthorityURLSocketTests: Sendable {
    private func exercise(_ mode: CloudAuthorityLoopbackServer.Mode = .upgrade,
                          _ body: @Sendable (CloudAuthorityLoopbackServer, URL) async throws -> Void) async throws {
        let server = CloudAuthorityLoopbackServer(mode: mode)
        do {
            let origin = try await withDeadline(.seconds(5), label: "loopback listener bind") { try await server.start() }
            try await body(server, origin)
            await server.stop()
        } catch { await server.stop(); throw error }
    }

    private func connected(_ lease: CloudAuthorityWireLease, mode: CloudAuthorityLoopbackServer.Mode = .upgrade,
                           _ body: @Sendable (CloudAuthorityLoopbackServer, any CloudAuthorityWireSocket) async throws -> Void) async throws {
        try await exercise(mode) { server, origin in
            let socket = try CloudAuthorityWireTransport(origin: origin, headers: ["x-cmux-client-version": "2.4.0"]).connect(lease)
            do { try await body(server, socket); await socket.close() }
            catch { await socket.close(); throw error }
        }
    }

    @Test(arguments: ["user", "team"])
    func productionURLSessionSendsOnlyHeaderCredentialsAndExchangesFrames(owner: String) async throws {
        let lease = try CloudAuthorityWireWorld.lease(owner: owner == "user" ? .user : .team)
        try await connected(lease) { server, socket in
            let incoming = await server.read(socket)
            let request = try await withDeadline(.seconds(5), label: "owner upgrade request") { try await server.nextRequest() }
            #expect(request.target == "/v1/wire/" + owner)
            #expect(request.headers["authorization"] == "Bearer " + lease.token)
            #expect(request.headers["x-cmux-client-version"] == "2.4.0")
            #expect(request.headers["cookie"] == nil)
            let expected = owner == "team" ? Set(["cmux.wire.v1", "team." + lease.team]) : Set(["cmux.wire.v1"])
            let protocols = (request.headers["sec-websocket-protocol"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            #expect(Set(protocols) == expected && protocols.count == expected.count)
            #expect(request.headers.filter { $0.key != "authorization" }.values.allSatisfy { !$0.contains(lease.token) })
            let peer = try await server.peer(request.id), greeting = Data("real-socket-message".utf8)
            try await peer.frame(greeting, opcode: 1)
            #expect(try await incoming.result().get() == greeting)
            let subscribe = Data(#"{"t":"subscribe","pending":[]}"#.utf8)
            try await socket.send(subscribe)
            let sent = try await withDeadline(.seconds(5), label: "client binary frame") { try await peer.nextFrame() }
            #expect(sent.opcode == 2 && sent.payload == subscribe)
        }
    }

    @Test func cancellingAReceiveClosesTheEstablishedConnectionBeforeExplicitCleanup() async throws {
        try await connected(CloudAuthorityWireWorld.lease()) { server, socket in
            let opening = await server.read(socket)
            let request = try await withDeadline(.seconds(5), label: "cancellation upgrade") { try await server.nextRequest() }
            let peer = try await server.peer(request.id), ready = Data("ready".utf8)
            try await peer.frame(ready)
            #expect(try await opening.result().get() == ready)
            let pending = await server.read(socket)
            await pending.cancel()
            let result = try await pending.result()
            if case .success = result { Issue.record("A cancelled receive returned a message") }
            // This runs before connected() explicitly closes the socket; a deadline is a failure, not EOF evidence.
            try await withDeadline(.seconds(5), label: "client cancellation closes TCP") { try await peer.waitForClientClose() }
        }
    }

    @Test(arguments: [301, 302, 303, 307, 308])
    func sameOriginRedirectsCannotReuseTheBearer(status: Int) async throws {
        try await connected(CloudAuthorityWireWorld.lease(), mode: .redirect(status, nil)) { server, socket in
            let read = await server.read(socket)
            let result = try await read.result()
            if case .success = result { Issue.record("A redirected handshake became a WebSocket") }
            await socket.close(); await server.stop()
            let targets = await server.targets
            #expect(!targets.isEmpty && targets.allSatisfy { $0 == "/v1/wire/team" })
        }
    }

    @Test func anHTTPRedirectCannotReuseTheBearerWithinItsOrigin() async throws {
        try await exercise { server, origin in
            await server.setMode(.redirect(302, origin.appendingPathComponent("redirected")))
            let socket = try CloudAuthorityWireTransport(origin: origin, headers: [:]).connect(CloudAuthorityWireWorld.lease())
            let result = try await server.read(socket).result()
            if case .success = result { Issue.record("An HTTP redirect became a WebSocket") }
            await socket.close(); await server.stop()
            let targets = await server.targets
            #expect(!targets.isEmpty && targets.allSatisfy { $0 == "/v1/wire/team" })
        }
    }

    @Test(arguments: ["http", "ws"])
    func aCrossOriginRedirectNeverContactsItsDestination(scheme: String) async throws {
        try await exercise(.refuse(400, false)) { destination, url in
            let location = url.appendingPathComponent("redirected").absoluteString.replacingOccurrences(of: "http://", with: scheme + "://")
            let target = try #require(URL(string: location))
            try await connected(CloudAuthorityWireWorld.lease(), mode: .redirect(302, target)) { server, socket in
                let result = try await server.read(socket).result()
                if case .success = result { Issue.record("A redirected handshake became a WebSocket") }
                await socket.close(); await server.stop()
                let targets = await server.targets
                #expect(!targets.isEmpty && targets.allSatisfy { $0 == "/v1/wire/team" })
            }
            await destination.stop()
            #expect(await destination.accepted == 0)
            #expect(await destination.targets.isEmpty)
        }
    }

    @Test func aRefusedHandshakeCannotSeedCookiesForTheNextOwnerSocket() async throws {
        let lease = try CloudAuthorityWireWorld.lease()
        try await exercise(.refuse(403, true)) { server, origin in
            let transport = CloudAuthorityWireTransport(origin: origin, headers: [:])
            let refused = try transport.connect(lease)
            let result = try await server.read(refused).result()
            if case .success = result { Issue.record("A refused handshake became a WebSocket") }
            await refused.close()
            _ = try await withDeadline(.seconds(5), label: "refused upgrade recorded") { try await server.nextRequest() }
            await server.setMode(.upgrade)
            let next = try transport.connect(lease), pending = await server.read(next)
            do {
                let request = try await withDeadline(.seconds(5), label: "second owner upgrade") { try await server.nextRequest() }
                #expect(request.headers["cookie"] == nil)
                let peer = try await server.peer(request.id), reply = Data("new-private-session".utf8)
                try await peer.frame(reply)
                #expect(try await pending.result().get() == reply)
                await next.close()
            } catch { await next.close(); throw error }
        }
    }

    @Test(arguments: [8 << 20, (8 << 20) + 1])
    func theRealReceiverEnforcesItsMessageSizeLimit(size: Int) async throws {
        try await connected(CloudAuthorityWireWorld.lease()) { server, socket in
            let pending = await server.read(socket)
            let request = try await withDeadline(.seconds(5), label: "size-limit upgrade") { try await server.nextRequest() }
            let peer = try await server.peer(request.id)
            // The oversized case can close TCP before the sender finishes; retain and join both directions.
            let sending = Task { try await peer.frame(Data(repeating: 97, count: size)) }
            do {
                let result = try await pending.result()
                if size <= 8 << 20 { #expect(try result.get().count == size) }
                else if case .success = result { Issue.record("An oversized WebSocket message escaped the configured limit") }
                await socket.close(); await peer.close(); _ = await sending.result
            } catch {
                sending.cancel(); await socket.close(); await peer.close()
                _ = await sending.result
                throw error
            }
        }
    }

    @Test func realTransportLossPublishesBeforeAHeldAuthorityCheckDrains() async throws {
        try await exercise { server, origin in
            let authority = CloudAuthorityWireWorld(), transport = CloudAuthorityWireTransport(origin: origin, headers: [:])
            let wire = CloudAuthorityWire(lease: try CloudAuthorityWireWorld.lease(), connect: { try transport.connect($0) },
                recheck: { try await authority.check() }, now: { CloudAuthorityWireWorld.now },
                sleep: { try await authority.clock.sleep($0) })
            let running = Task { try await wire.run() }, events = wire.events
            do {
                let request = try await withDeadline(.seconds(5), label: "checked owner upgrade") { try await server.nextRequest() }
                let peer = try await server.peer(request.id)
                try await peer.frame(Data(CloudAuthorityWireWorld.welcome().utf8), opcode: 1)
                try await peer.frame(Data(CloudAuthorityWireWorld.snapshot.utf8), opcode: 1)
                let ready = try await withDeadline(.seconds(5), label: "real checked owner ready") {
                    var iterator = events.makeAsyncIterator(); return await iterator.next()
                }
                #expect(ready == .ready)
                let subscription = try await withDeadline(.seconds(5), label: "real owner subscribe") { try await peer.nextFrame() }
                let body = try #require(JSONSerialization.jsonObject(with: subscription.payload) as? [String: Any])
                #expect(body["t"] as? String == "subscribe")
                #expect((body["pending"] as? [String])?.isEmpty == true)
                await authority.holdNextCheck()
                try await peer.frame(Data(#"{"t":"event","stream":"team:team_1","seq":1}"#.utf8), opcode: 1)
                try await withDeadline(.seconds(5), label: "authority check held") { await authority.waitUntilHeld() }
                await peer.close()
                let lost = try await withDeadline(.seconds(5), label: "real socket EOF closes admission") {
                    var iterator = events.makeAsyncIterator(); return await iterator.next()
                }
                #expect(lost == .lost)
                await authority.release()
                _ = await running.result
                var finished = events.makeAsyncIterator()
                #expect(await finished.next() == nil)
                await authority.clock.finish()
            } catch {
                await authority.release(); running.cancel(); await server.stop()
                _ = await running.result
                await authority.clock.finish()
                throw error
            }
        }
    }
}
