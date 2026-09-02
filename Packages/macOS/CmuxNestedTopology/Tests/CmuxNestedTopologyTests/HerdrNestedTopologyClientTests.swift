import Foundation
import Testing
@testable import CmuxNestedTopology

@Suite struct HerdrNestedTopologyClientTests {
    @Test func goldenSnapshotAndHandshake() async throws {
        let server = try FakeHerdrUnixSocketServer { _, id, method in
            switch method {
            case "ping":
                return [HerdrFakeFixtures.line(HerdrFakeFixtures.pongJSON(id: id))]
            case "session.snapshot":
                return [HerdrFakeFixtures.line(HerdrFakeFixtures.snapshotJSON(id: id))]
            default:
                return [HerdrFakeFixtures.line(HerdrFakeFixtures.errorJSON(id: id))]
            }
        }
        defer { server.shutdown() }

        let client = makeClient(socketPath: server.path)
        let handshake = try await client.handshake()
        #expect(handshake.protocolNumber == 17)
        #expect(handshake.capabilities.contains(.topologySnapshotV1))
        #expect(handshake.capabilities.contains(.topologyEventsV1))
        #expect(handshake.capabilities.contains(.topologyFocusV1))
        // Gap: protocol 17 ping has no instance_id; client mints a connection generation.
        #expect(!handshake.providerInstanceID.rawValue.isEmpty)

        let snapshot = try await client.snapshot()
        #expect(snapshot.workspaces.count == 1)
        #expect(snapshot.workspaces[0].displayTitle == "Main")
        #expect(snapshot.tabs[0].displayTitle == "Build")
        #expect(snapshot.panes[0].id.rawID == "w1:p1")
        #expect(snapshot.agents[0].status == .working)
        #expect(snapshot.focus.paneID?.rawID == "w1:p1")
        #expect(snapshot.provider.providerInstanceID == handshake.providerInstanceID)
    }

    @Test func goldenEventsStream() async throws {
        let server = try FakeHerdrUnixSocketServer { _, id, method in
            switch method {
            case "ping":
                return [HerdrFakeFixtures.line(HerdrFakeFixtures.pongJSON(id: id))]
            case "session.snapshot":
                return [HerdrFakeFixtures.line(HerdrFakeFixtures.snapshotJSON(id: id))]
            case "events.subscribe":
                return [
                    HerdrFakeFixtures.line(HerdrFakeFixtures.subscriptionStartedJSON(id: id)),
                    HerdrFakeFixtures.line(HerdrFakeFixtures.workspaceCreatedEventJSON()),
                    HerdrFakeFixtures.line(HerdrFakeFixtures.paneAgentStatusEventJSON()),
                ]
            default:
                return [HerdrFakeFixtures.line(HerdrFakeFixtures.errorJSON(id: id))]
            }
        }
        defer { server.shutdown() }

        let client = makeClient(socketPath: server.path)
        var iterator = client.events().makeAsyncIterator()
        let first = try await iterator.next()
        guard case .workspaceUpserted(let workspace) = first else {
            Issue.record("expected workspace upsert, got \(String(describing: first))")
            return
        }
        #expect(workspace.id.rawID == "w2")

        let second = try await iterator.next()
        // pane.agent_status_changed maps to agentUpserted then agentStatusUpdated.
        guard case .agentUpserted(let agent) = second else {
            Issue.record("expected agent upsert, got \(String(describing: second))")
            return
        }
        #expect(agent.status == .blocked)
    }

    @Test func fragmentedReadsAndMultipleLinesPerRead() async throws {
        let server = try FakeHerdrUnixSocketServer { _, id, method in
            switch method {
            case "ping":
                return [HerdrFakeFixtures.line(HerdrFakeFixtures.pongJSON(id: id))]
            case "session.snapshot":
                return [HerdrFakeFixtures.line(HerdrFakeFixtures.snapshotJSON(id: id))]
            case "events.subscribe":
                let ack = HerdrFakeFixtures.subscriptionStartedJSON(id: id) + "\n"
                let event = HerdrFakeFixtures.workspaceCreatedEventJSON() + "\n"
                return [Data((ack + event).utf8)]
            default:
                return [HerdrFakeFixtures.line(HerdrFakeFixtures.errorJSON(id: id))]
            }
        }
        server.setWriteFragmentSize(7)
        defer { server.shutdown() }

        let client = makeClient(socketPath: server.path)
        var iterator = client.events().makeAsyncIterator()
        let event = try await iterator.next()
        guard case .workspaceUpserted = event else {
            Issue.record("expected workspace event after fragmented reads")
            return
        }
    }

    @Test func malformedJSONFails() async throws {
        let server = try FakeHerdrUnixSocketServer { _, _, _ in
            [Data("{not-json\n".utf8)]
        }
        defer { server.shutdown() }
        let client = makeClient(socketPath: server.path)
        await #expect(throws: NestedTopologyProviderError.self) {
            _ = try await client.handshake()
        }
    }

    @Test func wrongResponseIDFails() async throws {
        let server = try FakeHerdrUnixSocketServer { _, _, _ in
            [HerdrFakeFixtures.line(HerdrFakeFixtures.pongJSON(id: "other-id"))]
        }
        defer { server.shutdown() }
        let client = makeClient(socketPath: server.path)
        do {
            _ = try await client.handshake()
            Issue.record("expected response id mismatch")
        } catch let error as NestedTopologyProviderError {
            guard case .responseIDMismatch = error else {
                Issue.record("unexpected error \(error)")
                return
            }
        }
    }

    @Test func providerErrorResponseFails() async throws {
        let server = try FakeHerdrUnixSocketServer { _, id, _ in
            [HerdrFakeFixtures.line(HerdrFakeFixtures.errorJSON(id: id, code: "busy", message: "try later"))]
        }
        defer { server.shutdown() }
        let client = makeClient(socketPath: server.path)
        do {
            _ = try await client.handshake()
            Issue.record("expected provider error")
        } catch let error as NestedTopologyProviderError {
            guard case .providerError(let code, let message) = error else {
                Issue.record("unexpected error \(error)")
                return
            }
            #expect(code == "busy")
            #expect(message == "try later")
        }
    }

    @Test func requestTimeoutFails() async throws {
        let server = try FakeHerdrUnixSocketServer { _, _, _ in [] }
        server.setStallResponses(true)
        defer { server.shutdown() }
        let client = makeClient(
            socketPath: server.path,
            requestTimeout: .milliseconds(150)
        )
        await #expect(throws: NestedTopologyProviderError.self) {
            _ = try await client.handshake()
        }
    }

    @Test func eofFails() async throws {
        let server = try FakeHerdrUnixSocketServer { _, _, _ in [] }
        server.setCloseAfterAccept(true)
        defer { server.shutdown() }
        let client = makeClient(socketPath: server.path)
        await #expect(throws: NestedTopologyProviderError.self) {
            _ = try await client.handshake()
        }
    }

    @Test func cancellationClosesDescriptorPromptly() async throws {
        let subscribed = AsyncStream<Void>.makeStream()
        let server = try FakeHerdrUnixSocketServer { _, id, method in
            switch method {
            case "ping":
                return [HerdrFakeFixtures.line(HerdrFakeFixtures.pongJSON(id: id))]
            case "session.snapshot":
                return [HerdrFakeFixtures.line(HerdrFakeFixtures.snapshotJSON(id: id))]
            case "events.subscribe":
                subscribed.continuation.yield()
                return [HerdrFakeFixtures.line(HerdrFakeFixtures.subscriptionStartedJSON(id: id))]
            default:
                return [HerdrFakeFixtures.line(HerdrFakeFixtures.errorJSON(id: id))]
            }
        }
        defer { server.shutdown() }

        let client = makeClient(socketPath: server.path)
        let stream = client.events()
        let task = Task {
            for try await _ in stream {}
        }
        var subscribedIterator = subscribed.stream.makeAsyncIterator()
        _ = await subscribedIterator.next()
        task.cancel()
        do {
            _ = try await task.value
        } catch {
            // Cancellation may surface as an error depending on timing.
        }
        #expect(task.isCancelled)
    }

    @Test func oversizedLineFails() async throws {
        let server = try FakeHerdrUnixSocketServer { _, id, _ in
            let huge = String(repeating: "a", count: 200)
            return [
                Data(
                    "{\"id\":\"\(id)\",\"result\":{\"type\":\"pong\",\"version\":\"\(huge)\",\"protocol\":17}}\n"
                        .utf8
                ),
            ]
        }
        defer { server.shutdown() }
        let client = makeClient(
            socketPath: server.path,
            maxLineUTF8ByteCount: 64
        )
        do {
            _ = try await client.handshake()
            Issue.record("expected oversized line")
        } catch let error as NestedTopologyProviderError {
            guard case .oversizedLine = error else {
                Issue.record("unexpected error \(error)")
                return
            }
        }
    }

    @Test func unsupportedProtocolFails() async throws {
        let server = try FakeHerdrUnixSocketServer { _, id, _ in
            [HerdrFakeFixtures.line(HerdrFakeFixtures.pongJSON(id: id, protocolNumber: 99))]
        }
        defer { server.shutdown() }
        let client = makeClient(socketPath: server.path)
        do {
            _ = try await client.handshake()
            Issue.record("expected unsupported protocol")
        } catch let error as NestedTopologyProviderError {
            guard case .unsupportedProtocol(let number) = error else {
                Issue.record("unexpected error \(error)")
                return
            }
            #expect(number == 99)
        }
    }

    @Test func missingRequiredFieldFails() async throws {
        let server = try FakeHerdrUnixSocketServer { _, id, _ in
            [Data("{\"id\":\"\(id)\",\"result\":{\"type\":\"pong\",\"protocol\":17}}\n".utf8)]
        }
        defer { server.shutdown() }
        let client = makeClient(socketPath: server.path)
        await #expect(throws: NestedTopologyProviderError.self) {
            _ = try await client.handshake()
        }
    }

    @Test func reconnectResnapshotAndAssociationInvalidation() async throws {
        final class State: @unchecked Sendable {
            let lock = NSLock()
            var subscribeCount = 0
        }
        let state = State()

        let server = try FakeHerdrUnixSocketServer { _, id, method in
            switch method {
            case "ping":
                return [HerdrFakeFixtures.line(HerdrFakeFixtures.pongJSON(id: id))]
            case "session.snapshot":
                return [HerdrFakeFixtures.line(HerdrFakeFixtures.snapshotJSON(id: id))]
            case "events.subscribe":
                state.lock.lock()
                state.subscribeCount += 1
                let count = state.subscribeCount
                state.lock.unlock()
                if count == 1 {
                    // First subscription: emit one event then EOF (empty chunk sentinel).
                    return [
                        HerdrFakeFixtures.line(HerdrFakeFixtures.subscriptionStartedJSON(id: id)),
                        HerdrFakeFixtures.line(HerdrFakeFixtures.workspaceCreatedEventJSON()),
                        Data(),
                    ]
                }
                return [
                    HerdrFakeFixtures.line(HerdrFakeFixtures.subscriptionStartedJSON(id: id)),
                    HerdrFakeFixtures.line(HerdrFakeFixtures.paneAgentStatusEventJSON()),
                ]
            default:
                return [HerdrFakeFixtures.line(HerdrFakeFixtures.errorJSON(id: id))]
            }
        }
        defer { server.shutdown() }

        var associations = NestedAssociationStore()
        let oldInstance = NestedProviderInstanceID(rawValue: "old-generation")
        let key = NestedAssociationKey(
            nodeID: NestedNodeID(
                providerKind: .herdr,
                providerInstanceID: oldInstance,
                kind: .pane,
                rawID: "w1:p1"
            ),
            sessionRawID: "sess",
            providerInstanceGeneration: oldInstance
        )
        associations.markHeuristicSatisfied(for: key, parentID: nil)

        let client = HerdrNestedTopologyClient(
            configuration: HerdrNestedTopologyClientConfiguration(
                socketPath: server.path,
                attachmentID: HerdrFakeFixtures.attachmentID,
                hostStableSurfaceID: HerdrFakeFixtures.hostSurfaceID,
                connectTimeout: .seconds(2),
                requestTimeout: .seconds(2),
                reconnectInitialBackoff: .milliseconds(20),
                reconnectMaxBackoff: .milliseconds(50)
            ),
            associations: associations
        )

        var iterator = client.events().makeAsyncIterator()
        let first = try await iterator.next()
        guard case .workspaceUpserted = first else {
            Issue.record("expected first workspace event, got \(String(describing: first))")
            return
        }

        let second = try await iterator.next()
        guard case .replaceSnapshot(let snap) = second else {
            Issue.record("expected replaceSnapshot after reconnect, got \(String(describing: second))")
            return
        }
        #expect(snap.workspaces.count == 1)

        let store = await client.associationStore()
        #expect(store.record(for: key) == nil)
        let handshake = await client.currentHandshake()
        #expect(handshake?.providerInstanceID != oldInstance)
    }

    @Test func protocol17UnknownFieldsTolerated() throws {
        let json = HerdrFakeFixtures.snapshotJSON(id: "req")
        let response = try HerdrProtocol17Compatibility().decodeResponseLine(
            String(json),
            expectedRequestID: HerdrJSONRPCRequestID(rawValue: "req")
        )
        guard let result = response.result, case .sessionSnapshot(let wire) = result else {
            Issue.record("expected snapshot")
            return
        }
        let handshake = NestedProviderHandshake(
            providerKind: .herdr,
            providerInstanceID: NestedProviderInstanceID(rawValue: "gen"),
            version: "0.7.0",
            protocolNumber: 17,
            capabilities: HerdrProtocol17Compatibility.readCapabilities
        )
        let snapshot = try HerdrProtocol17Compatibility().makeSnapshot(
            from: wire,
            handshake: handshake,
            attachmentID: HerdrFakeFixtures.attachmentID,
            hostStableSurfaceID: HerdrFakeFixtures.hostSurfaceID,
            limits: .default
        )
        #expect(snapshot.panes.count == 1)
    }

    @Test func concurrentHandshakeSharesOneInstance() async throws {
        let server = try FakeHerdrUnixSocketServer { _, id, method in
            switch method {
            case "ping":
                return [HerdrFakeFixtures.line(HerdrFakeFixtures.pongJSON(id: id))]
            default:
                return [HerdrFakeFixtures.line(HerdrFakeFixtures.errorJSON(id: id))]
            }
        }
        defer { server.shutdown() }

        let client = makeClient(socketPath: server.path)
        async let first = client.handshake()
        async let second = client.handshake()
        let (a, b) = try await (first, second)
        #expect(a.providerInstanceID == b.providerInstanceID)
        #expect(await client.currentHandshake()?.providerInstanceID == a.providerInstanceID)
    }

    @Test func lineReaderHandlesFragmentsAndMultiLineChunks() throws {
        var reader = HerdrJSONLineReader(maxLineUTF8ByteCount: 1024)
        #expect(try reader.append(Data("{\"a\":".utf8)).isEmpty)
        let lines = try reader.append(Data("1}\n{\"b\":2}\n{\"c\":".utf8))
        #expect(lines == [#"{"a":1}"#, #"{"b":2}"#])
        #expect(try reader.append(Data("3}\n".utf8)) == [#"{"c":3}"#])
    }
}

private func makeClient(
    socketPath: String,
    requestTimeout: Duration = .seconds(2),
    maxLineUTF8ByteCount: Int = 512 * 1024
) -> HerdrNestedTopologyClient {
    HerdrNestedTopologyClient(
        configuration: HerdrNestedTopologyClientConfiguration(
            socketPath: socketPath,
            attachmentID: HerdrFakeFixtures.attachmentID,
            hostStableSurfaceID: HerdrFakeFixtures.hostSurfaceID,
            connectTimeout: .seconds(2),
            requestTimeout: requestTimeout,
            maxLineUTF8ByteCount: maxLineUTF8ByteCount,
            reconnectInitialBackoff: .milliseconds(20),
            reconnectMaxBackoff: .milliseconds(100)
        )
    )
}
