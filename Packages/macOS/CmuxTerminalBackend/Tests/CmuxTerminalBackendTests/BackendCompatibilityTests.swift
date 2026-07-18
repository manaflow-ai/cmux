import CmuxTerminalBackend
import Foundation
import Testing

@Suite("Backend read-only compatibility")
struct BackendCompatibilityTests {
    private struct Scenario {
        let name: String
        let serverRange: ClosedRange<UInt32>
        let capabilities: Set<String>
        let expectedNegotiatedProtocol: UInt32?
        let expectedReasons: Set<BackendReadOnlyReason>
        let expectedMissingCapabilities: Set<String>

        var isReadWrite: Bool { expectedReasons.isEmpty }
        var expectsTopologyProjection: Bool {
            expectedNegotiatedProtocol != nil
                && capabilities.isSuperset(of: [
                    "canonical-topology-snapshot-v1",
                    "topology-resume-v1",
                ])
        }
    }

    @Test("version matrix connects read-only without dispatching rejected mutations")
    func versionMatrix() async throws {
        let fullCapabilities = BackendHandshakePolicy.terminalAuthorityV1.requiredCapabilities
        let missingCapability = "terminal-input-groups-v1"
        let scenarios = [
            Scenario(
                name: "v9-complete",
                serverRange: 8 ... 9,
                capabilities: fullCapabilities,
                expectedNegotiatedProtocol: 9,
                expectedReasons: [],
                expectedMissingCapabilities: []
            ),
            Scenario(
                name: "v8-baseline",
                serverRange: 8 ... 8,
                capabilities: fullCapabilities,
                expectedNegotiatedProtocol: 8,
                expectedReasons: [.protocolTooOld],
                expectedMissingCapabilities: []
            ),
            Scenario(
                name: "incompatible-future",
                serverRange: 10 ... 11,
                capabilities: fullCapabilities,
                expectedNegotiatedProtocol: nil,
                expectedReasons: [.incompatibleProtocol],
                expectedMissingCapabilities: []
            ),
            Scenario(
                name: "v9-missing-mutation-capability",
                serverRange: 8 ... 9,
                capabilities: fullCapabilities.subtracting([missingCapability]),
                expectedNegotiatedProtocol: 9,
                expectedReasons: [.missingCapabilities],
                expectedMissingCapabilities: [missingCapability]
            ),
            Scenario(
                name: "v9-missing-topology-capability",
                serverRange: 8 ... 9,
                capabilities: fullCapabilities.subtracting([
                    "canonical-topology-snapshot-v1",
                ]),
                expectedNegotiatedProtocol: 9,
                expectedReasons: [.missingCapabilities],
                expectedMissingCapabilities: ["canonical-topology-snapshot-v1"]
            ),
        ]

        for scenario in scenarios {
            let connection = try await connect(scenario)
            let compatibility = try await connection.session.compatibility()
            #expect(compatibility.negotiatedProtocol == scenario.expectedNegotiatedProtocol)

            if scenario.isReadWrite {
                guard case .readWrite(let readWrite) = compatibility else {
                    Issue.record("\(scenario.name): expected read-write compatibility")
                    continue
                }
                #expect(readWrite.negotiatedProtocol == 9)
                #expect(await connection.transport.commandLog() == [
                    "identify", "register-client", "topology-snapshot", "subscribe-topology",
                    "terminal-activity-snapshot",
                ])
            } else {
                guard case .readOnly(let diagnostic) = compatibility else {
                    Issue.record("\(scenario.name): expected read-only compatibility")
                    continue
                }
                #expect(diagnostic.clientProtocolRange == 8 ... 9)
                #expect(diagnostic.serverProtocolRange == scenario.serverRange)
                #expect(diagnostic.reasons == scenario.expectedReasons)
                #expect(diagnostic.missingCapabilities == scenario.expectedMissingCapabilities)
                #expect(diagnostic.upgradeAction == .updateCmux)
                let expectedConnectCommands = scenario.expectsTopologyProjection
                    ? ["identify", "topology-snapshot", "subscribe-topology"]
                    : ["identify"]
                #expect(await connection.transport.commandLog() == expectedConnectCommands)
                #expect(
                    (await connection.session.currentSnapshot() != nil)
                        == scenario.expectsTopologyProjection
                )

                let commandLog = await connection.transport.commandLog()
                let stateDigest = await connection.transport.stateDigest()
                do {
                    _ = try await connection.session.newWorkspace(name: "must-not-dispatch")
                    Issue.record("\(scenario.name): read-only mutation unexpectedly succeeded")
                } catch let error as BackendProtocolError {
                    guard case .mutationUnavailableInReadOnlyMode(
                        let command,
                        let rejectedDiagnostic
                    ) = error else {
                        Issue.record("\(scenario.name): unexpected mutation error \(error)")
                        continue
                    }
                    #expect(command == "new-workspace")
                    #expect(rejectedDiagnostic == diagnostic)
                }
                #expect(await connection.transport.commandLog() == commandLog)
                #expect(await connection.transport.stateDigest() == stateDigest)
            }
            await connection.session.close()
        }
    }

    @Test("read-only mode dispatches diagnostics and preserves fake server state")
    func readOnlyDiagnostics() async throws {
        let scenario = Scenario(
            name: "v8-diagnostics",
            serverRange: 8 ... 8,
            capabilities: BackendHandshakePolicy.terminalAuthorityV1.requiredCapabilities,
            expectedNegotiatedProtocol: 8,
            expectedReasons: [.protocolTooOld],
            expectedMissingCapabilities: []
        )
        let connection = try await connect(scenario)
        let session = connection.session
        let transport = connection.transport
        let stateDigest = await transport.stateDigest()

        #expect(try await session.backendIdentity().authority == connection.authority)
        #expect(await session.currentSnapshot()?.authority == connection.authority)

        let healthTask = Task { try await session.health() }
        let health = try requestObject(await transport.nextSent())
        #expect(health["cmd"] as? String == "ping")
        await transport.enqueue(try response(to: health, data: healthResponse(
            authority: connection.authority,
            capabilities: scenario.capabilities
        )))
        #expect(try await healthTask.value.authority == connection.authority)

        let presentationsTask = Task { try await session.listPresentations() }
        let presentations = try requestObject(await transport.nextSent())
        #expect(presentations["cmd"] as? String == "list-presentations")
        await transport.enqueue(try response(to: presentations, data: [] as [Any]))
        #expect(try await presentationsTask.value.isEmpty)

        let processTask = Task { try await session.terminalProcessInfo(surface: 7) }
        let process = try requestObject(await transport.nextSent())
        #expect(process["cmd"] as? String == "process-info")
        await transport.enqueue(try response(to: process, data: [
            "pid": 700,
            "command": ["/bin/zsh"],
            "cwd": "/tmp",
            "tty": "/dev/ttys007",
        ]))
        #expect(try await processTask.value.processID == 700)

        let screenTask = Task { try await session.readTerminalScreen(surface: 7) }
        let screen = try requestObject(await transport.nextSent())
        #expect(screen["cmd"] as? String == "read-screen")
        await transport.enqueue(try response(to: screen, data: ["text": "diagnostic"] ))
        #expect(try await screenTask.value.text == "diagnostic")

        let presentationID = PresentationID(rawValue: UUID())
        let accessibilityTask = Task {
            try await session.terminalAccessibilitySnapshot(
                presentationID: presentationID,
                expectedGeneration: 1,
                expectedContentSequence: 1
            )
        }
        let accessibility = try requestObject(await transport.nextSent())
        #expect(accessibility["cmd"] as? String == "terminal-accessibility-snapshot")
        #expect(accessibility["expected_content_sequence"] as? NSNumber == 1)
        await transport.enqueue(try response(
            to: accessibility,
            data: accessibilityResponse(presentationID: presentationID)
        ))
        #expect(try await accessibilityTask.value.text == "x")

        let projectionsTask = Task { try await session.listProjectionStates() }
        let projections = try requestObject(await transport.nextSent())
        #expect(projections["cmd"] as? String == "list-projection-states")
        await transport.enqueue(try response(to: projections, data: [] as [Any]))
        #expect(try await projectionsTask.value.isEmpty)

        #expect(await transport.stateDigest() == stateDigest)
        #expect(await transport.commandLog() == [
            "identify",
            "topology-snapshot",
            "subscribe-topology",
            "ping",
            "list-presentations",
            "process-info",
            "read-screen",
            "terminal-accessibility-snapshot",
            "list-projection-states",
        ])
        await session.close()
    }

    private struct Connection {
        let session: BackendCanonicalSession
        let transport: ScriptedBackendTransport
        let authority: BackendAuthority
    }

    private func connect(_ scenario: Scenario) async throws -> Connection {
        let transport = ScriptedBackendTransport()
        let authority = BackendAuthority(
            daemonInstanceID: DaemonInstanceID(rawValue: UUID()),
            sessionID: SessionID(rawValue: UUID())
        )
        let identity = BackendClientRegistrationIdentity(
            clientUUID: UUID(),
            processInstanceUUID: UUID()
        )!
        let session = BackendCanonicalSession(
            transport: transport,
            expectation: BackendCanonicalSessionExpectation(
                session: "compatibility",
                authority: authority,
                processID: 4321
            ),
            registrationIdentity: identity
        )
        let task = Task { try await session.connect() }

        let identify = try requestObject(await transport.nextSent())
        #expect(identify["cmd"] as? String == "identify")
        await transport.enqueue(try response(to: identify, data: identifyResponse(
            authority: authority,
            serverRange: scenario.serverRange,
            capabilities: scenario.capabilities
        )))

        if scenario.isReadWrite {
            let register = try requestObject(await transport.nextSent())
            #expect(register["cmd"] as? String == "register-client")
            await transport.enqueue(try response(to: register, data: [
                "protocol": 9,
                "connection_id": UUID().uuidString,
                "client_uuid": identity.clientUUID.uuidString,
                "process_instance_uuid": identity.processInstanceUUID.uuidString,
            ]))
        }

        if scenario.expectsTopologyProjection {
            let snapshot = try requestObject(await transport.nextSent())
            #expect(snapshot["cmd"] as? String == "topology-snapshot")
            await transport.enqueue(try response(to: snapshot, data: [
                "daemon_instance_id": authority.daemonInstanceID.description,
                "session_id": authority.sessionID.description,
                "revision": 0,
                "topology": ["workspaces": []],
            ]))

            let subscribe = try requestObject(await transport.nextSent())
            #expect(subscribe["cmd"] as? String == "subscribe-topology")
            await transport.enqueue(try response(to: subscribe, data: [
                "status": "subscribed",
                "daemon_instance_id": authority.daemonInstanceID.description,
                "session_id": authority.sessionID.description,
                "from_revision": 0,
                "current_revision": 0,
                "replayed": 0,
            ]))
        }
        if scenario.isReadWrite {
            let activity = try requestObject(await transport.nextSent())
            #expect(activity["cmd"] as? String == "terminal-activity-snapshot")
            await transport.enqueue(try response(to: activity, data: [
                "reader_uuid": identity.clientUUID.uuidString,
                "latest_sequence": 0,
                "facts": [],
                "receipts": [],
            ]))
        }
        _ = try await task.value
        return Connection(session: session, transport: transport, authority: authority)
    }

    private func identifyResponse(
        authority: BackendAuthority,
        serverRange: ClosedRange<UInt32>,
        capabilities: Set<String>
    ) -> [String: Any] {
        [
            "app": "cmux-tui",
            "version": "0.1.0",
            "protocol": serverRange.upperBound,
            "protocol_min": serverRange.lowerBound,
            "protocol_max": serverRange.upperBound,
            "capabilities": capabilities.sorted(),
            "session": "compatibility",
            "session_id": authority.sessionID.description,
            "daemon_instance_id": authority.daemonInstanceID.description,
            "topology_revision": 0,
            "canonical_topology_revision": 0,
            "pid": 4321,
        ]
    }

    private func healthResponse(
        authority: BackendAuthority,
        capabilities: Set<String>
    ) -> [String: Any] {
        [
            "version": "0.1.0",
            "protocol": 8,
            "protocol_min": 8,
            "protocol_max": 8,
            "capabilities": capabilities.sorted(),
            "session": "compatibility",
            "session_id": authority.sessionID.description,
            "daemon_instance_id": authority.daemonInstanceID.description,
            "canonical_topology_revision": 0,
            "pid": 4321,
        ]
    }

    private func accessibilityResponse(presentationID: PresentationID) -> [String: Any] {
        [
            "schema_version": 1,
            "surface_uuid": UUID().uuidString,
            "presentation_id": presentationID.description,
            "presentation_generation": 1,
            "content_sequence": 1,
            "terminal_revision": 1,
            "content_revision": 1,
            "viewport_revision": 1,
            "viewport_offset": 0,
            "columns": 1,
            "rows": 1,
            "text": "x",
            "lines": [[
                "row": 0,
                "utf16_range": ["location": 0, "length": 1],
                "cells": [[
                    "column": 0,
                    "column_span": 1,
                    "utf16_range": ["location": 0, "length": 1],
                ]],
            ]],
            "selections": [],
            "links": [],
            "focused": false,
        ]
    }

    private func requestObject(_ data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func response(to request: [String: Any], data: Any) throws -> Data {
        try encodedJSON([
            "id": try #require(request["id"] as? NSNumber).uint64Value,
            "ok": true,
            "data": data,
        ])
    }
}
