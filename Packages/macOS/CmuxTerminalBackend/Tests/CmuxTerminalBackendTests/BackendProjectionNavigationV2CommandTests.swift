@testable import CmuxTerminalBackend
import Foundation
import Testing

@Suite("Daemon-retained projection navigation v2 commands")
struct BackendProjectionNavigationV2CommandTests {
    @Test("claim, mutate with every operation, and release preserve exact v2 fences")
    func mutationWireContract() async throws {
        let transport = ScriptedBackendTransport()
        let client = BackendProtocolClient(transport: transport)
        try await client.connect()
        let authority = try authority()
        let identifiers = try identifiers()

        let claimTask = Task {
            try await client.claimProjectionNavigationV2(
                logicalPresentationID: identifiers.logicalPresentationID,
                authority: authority,
                expectedTopologyRevision: 41
            )
        }
        let claimRequest = try request(await transport.nextSent())
        #expect(claimRequest["cmd"] as? String == "claim-projection-navigation-v2")
        #expect(
            claimRequest["logical_presentation_id"] as? String
                == identifiers.logicalPresentationID.uuidString.lowercased()
        )
        try expectAuthority(claimRequest, authority: authority, topologyRevision: 41)
        await transport.enqueue(try response(
            to: claimRequest,
            data: appliedPayload(
                topologyRevision: 41,
                states: [statePayload(identifiers: identifiers, generation: 7)]
            )
        ))
        guard case .applied(let claim) = try await claimTask.value else {
            Issue.record("expected an applied claim")
            return
        }
        #expect(claim.states.count == 1)
        #expect(claim.states[0].claimID == identifiers.claimID)
        #expect(claim.clientRevision == nil)

        let operations: [BackendProjectionNavigationOperation] = [
            .assignWorkspace(workspaceID: identifiers.workspaceID),
            .unassignWorkspace(workspaceID: identifiers.secondWorkspaceID),
            .selectWorkspace(workspaceID: identifiers.workspaceID),
            .selectScreen(
                workspaceID: identifiers.workspaceID,
                screenID: identifiers.screenID
            ),
            .activatePane(
                workspaceID: identifiers.workspaceID,
                screenID: identifiers.screenID,
                paneID: identifiers.paneID
            ),
            .setZoomedPane(
                workspaceID: identifiers.workspaceID,
                screenID: identifiers.screenID,
                paneID: identifiers.paneID
            ),
            .selectSurface(
                workspaceID: identifiers.workspaceID,
                screenID: identifiers.screenID,
                paneID: identifiers.paneID,
                surfaceID: identifiers.surfaceID
            ),
        ]
        let mutation = BackendProjectionNavigationMutation(
            logicalPresentationID: identifiers.logicalPresentationID,
            claimID: identifiers.claimID,
            expectedGeneration: 7,
            operations: operations
        )
        let mutateTask = Task {
            try await client.mutateProjectionNavigationV2(
                requestID: identifiers.requestID,
                authority: authority,
                expectedTopologyRevision: 41,
                projections: [mutation]
            )
        }
        let mutateRequest = try request(await transport.nextSent())
        #expect(mutateRequest["cmd"] as? String == "mutate-projection-navigation-v2")
        #expect(
            mutateRequest["request_id"] as? String
                == identifiers.requestID.uuidString.lowercased()
        )
        try expectAuthority(mutateRequest, authority: authority, topologyRevision: 41)
        let projections = try #require(mutateRequest["projections"] as? [[String: Any]])
        #expect(projections.count == 1)
        #expect(
            projections[0]["logical_presentation_id"] as? String
                == identifiers.logicalPresentationID.uuidString.lowercased()
        )
        #expect(
            projections[0]["claim_id"] as? String
                == identifiers.claimID.uuidString.lowercased()
        )
        #expect(try uint64(projections[0], "expected_generation") == 7)
        let wireOperations = try #require(projections[0]["operations"] as? [[String: Any]])
        #expect(wireOperations.map { $0["type"] as? String } == [
            "assign-workspace",
            "unassign-workspace",
            "select-workspace",
            "select-screen",
            "activate-pane",
            "set-zoomed-pane",
            "select-surface",
        ])
        #expect(wireOperations[0]["workspace_uuid"] as? String == identifiers.workspaceID.description)
        #expect(wireOperations[1]["workspace_uuid"] as? String == identifiers.secondWorkspaceID.description)
        #expect(wireOperations[2]["workspace_uuid"] as? String == identifiers.workspaceID.description)
        #expect(wireOperations[3]["screen_uuid"] as? String == identifiers.screenID.description)
        #expect(wireOperations[4]["pane_uuid"] as? String == identifiers.paneID.description)
        #expect(wireOperations[5]["pane_uuid"] as? String == identifiers.paneID.description)
        #expect(wireOperations[6]["surface_uuid"] as? String == identifiers.surfaceID.description)
        await transport.enqueue(try response(
            to: mutateRequest,
            data: appliedPayload(
                topologyRevision: 41,
                states: [statePayload(identifiers: identifiers, generation: 8)]
            )
        ))
        guard case .applied(let mutationReceipt) = try await mutateTask.value else {
            Issue.record("expected an applied mutation")
            return
        }
        #expect(mutationReceipt.states.map(\.logicalPresentationID) == [
            identifiers.logicalPresentationID,
        ])

        let releaseTask = Task {
            try await client.releaseProjectionNavigationV2(
                requestID: identifiers.releaseRequestID,
                logicalPresentationID: identifiers.logicalPresentationID,
                claimID: identifiers.claimID,
                expectedGeneration: 8,
                authority: authority,
                expectedTopologyRevision: 41
            )
        }
        let releaseRequest = try request(await transport.nextSent())
        #expect(releaseRequest["cmd"] as? String == "release-projection-navigation-v2")
        #expect(
            releaseRequest["request_id"] as? String
                == identifiers.releaseRequestID.uuidString.lowercased()
        )
        #expect(try uint64(releaseRequest, "expected_generation") == 8)
        try expectAuthority(releaseRequest, authority: authority, topologyRevision: 41)
        await transport.enqueue(try response(
            to: releaseRequest,
            data: appliedPayload(topologyRevision: 41, states: [])
        ))
        guard case .applied(let release) = try await releaseTask.value else {
            Issue.record("expected an applied release")
            return
        }
        #expect(release.states.isEmpty)
        await client.close()
    }

    @Test("optional operation targets encode as explicit null values")
    func nullableOperationTargets() throws {
        let identifiers = try identifiers()
        let operations: [BackendProjectionNavigationOperation] = [
            .selectWorkspace(workspaceID: nil),
            .setZoomedPane(
                workspaceID: identifiers.workspaceID,
                screenID: identifiers.screenID,
                paneID: nil
            ),
        ]
        let encoded = try JSONEncoder().encode(operations)
        let objects = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [[String: Any]]
        )
        #expect(objects[0]["type"] as? String == "select-workspace")
        #expect(objects[0]["workspace_uuid"] is NSNull)
        #expect(objects[1]["type"] as? String == "set-zoomed-pane")
        #expect(objects[1]["pane_uuid"] is NSNull)
        #expect(try JSONDecoder().decode(
            [BackendProjectionNavigationOperation].self,
            from: encoded
        ) == operations)
    }

    @Test("structured conflicts retain every stale topology and stale generation field")
    func structuredConflicts() async throws {
        let transport = ScriptedBackendTransport()
        let client = BackendProtocolClient(transport: transport)
        try await client.connect()
        let expectedAuthority = try authority()
        let currentAuthority = BackendAuthority(
            daemonInstanceID: DaemonInstanceID(rawValue: try uuid("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")),
            sessionID: SessionID(rawValue: try uuid("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"))
        )
        let identifiers = try identifiers()

        let claimTask = Task {
            try await client.claimProjectionNavigationV2(
                logicalPresentationID: identifiers.logicalPresentationID,
                authority: expectedAuthority,
                expectedTopologyRevision: 41
            )
        }
        let claimRequest = try request(await transport.nextSent())
        await transport.enqueue(try response(to: claimRequest, data: [
            "status": "conflict",
            "conflict": [
                "code": "stale-topology",
                "expected_daemon_instance_id": expectedAuthority.daemonInstanceID.description,
                "current_daemon_instance_id": currentAuthority.daemonInstanceID.description,
                "expected_session_id": expectedAuthority.sessionID.description,
                "current_session_id": currentAuthority.sessionID.description,
                "expected_revision": 41,
                "current_revision": 42,
            ],
        ]))
        guard case .conflict(.staleTopology(
            let decodedExpectedAuthority,
            let decodedCurrentAuthority,
            let expectedRevision,
            let currentRevision
        )) = try await claimTask.value else {
            Issue.record("expected a structured stale-topology conflict")
            return
        }
        #expect(decodedExpectedAuthority == expectedAuthority)
        #expect(decodedCurrentAuthority == currentAuthority)
        #expect(expectedRevision == 41)
        #expect(currentRevision == 42)

        let mutation = BackendProjectionNavigationMutation(
            logicalPresentationID: identifiers.logicalPresentationID,
            claimID: identifiers.claimID,
            expectedGeneration: 6,
            operations: []
        )
        let mutateTask = Task {
            try await client.mutateProjectionNavigationV2(
                requestID: identifiers.requestID,
                authority: expectedAuthority,
                expectedTopologyRevision: 41,
                projections: [mutation]
            )
        }
        let mutateRequest = try request(await transport.nextSent())
        await transport.enqueue(try response(to: mutateRequest, data: [
            "status": "conflict",
            "conflict": [
                "code": "stale-generation",
                "logical_presentation_id": identifiers.logicalPresentationID.uuidString,
                "expected": 6,
                "current": 7,
                "current_state": statePayload(identifiers: identifiers, generation: 7),
            ],
        ]))
        guard case .conflict(.staleGeneration(
            let logicalPresentationID,
            let expected,
            let current,
            let currentState
        )) = try await mutateTask.value else {
            Issue.record("expected a structured stale-generation conflict")
            return
        }
        #expect(logicalPresentationID == identifiers.logicalPresentationID)
        #expect(expected == 6)
        #expect(current == 7)
        #expect(currentState.generation == 7)
        await client.close()
    }

    @Test("zero-capacity limits remain structured conflicts")
    func zeroCapacityLimitConflict() async throws {
        let transport = ScriptedBackendTransport()
        let client = BackendProtocolClient(transport: transport)
        try await client.connect()
        let authority = try authority()
        let identifiers = try identifiers()

        let task = Task {
            try await client.claimProjectionNavigationV2(
                logicalPresentationID: identifiers.logicalPresentationID,
                authority: authority,
                expectedTopologyRevision: 41
            )
        }
        let request = try request(await transport.nextSent())
        await transport.enqueue(try response(to: request, data: [
            "status": "conflict",
            "conflict": [
                "code": "limit-exceeded",
                "limit": "records-per-client",
                "maximum": 0,
                "attempted": 1,
            ],
        ]))
        guard case .conflict(.limitExceeded(let limit, let maximum, let attempted)) =
            try await task.value
        else {
            Issue.record("expected a zero-capacity limit conflict")
            return
        }
        #expect(limit == .recordsPerClient)
        #expect(maximum == 0)
        #expect(attempted == 1)
        await client.close()
    }

    @Test("malformed structured conflicts cannot enter reconciliation")
    func malformedStructuredConflicts() async throws {
        let authority = try authority()
        let identifiers = try identifiers()
        var staleState = statePayload(identifiers: identifiers, generation: 7)
        staleState["reconciled_topology_revision"] = 40
        let nilID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        let legacyState: [String: Any] = [
            "logical_presentation_id": identifiers.logicalPresentationID.uuidString,
            "generation": 7,
            "claim_id": identifiers.claimID.uuidString,
            "claimed_process_instance_uuid": identifiers.processInstanceID.uuidString,
            "workspaces": [
                [
                    "workspace_uuid": identifiers.workspaceID.description,
                    "selected_screen_uuid": identifiers.screenID.description,
                ],
                [
                    "workspace_uuid": identifiers.workspaceID.description,
                    "selected_screen_uuid": identifiers.screenID.description,
                ],
            ],
        ]
        let conflicts: [[String: Any]] = [
            [
                "code": "stale-generation",
                "logical_presentation_id": identifiers.logicalPresentationID.uuidString,
                "expected": 6,
                "current": 7,
                "current_state": staleState,
            ],
            [
                "code": "claim-lost",
                "logical_presentation_id": nilID.uuidString,
                "claimed_process_instance_uuid": NSNull(),
            ],
            [
                "code": "legacy-stale-generation",
                "logical_presentation_id": identifiers.logicalPresentationID.uuidString,
                "expected": 6,
                "current": 7,
                "current_state": legacyState,
            ],
        ]

        for conflict in conflicts {
            let transport = ScriptedBackendTransport()
            let client = BackendProtocolClient(transport: transport)
            try await client.connect()
            let task = Task {
                try await client.claimProjectionNavigationV2(
                    logicalPresentationID: identifiers.logicalPresentationID,
                    authority: authority,
                    expectedTopologyRevision: 41
                )
            }
            let request = try request(await transport.nextSent())
            await transport.enqueue(try response(to: request, data: [
                "status": "conflict",
                "conflict": conflict,
            ]))
            await #expect(throws: BackendProtocolError.malformedMessage) {
                try await task.value
            }
            await client.close()
        }
    }

    @Test("mutation receipts retain the requested claim and advance by at most one generation")
    func mutationReceiptFences() async throws {
        let authority = try authority()
        let identifiers = try identifiers()
        var wrongClaimState = statePayload(identifiers: identifiers, generation: 8)
        wrongClaimState["claim_id"] = UUID().uuidString
        let responses = [
            wrongClaimState,
            statePayload(identifiers: identifiers, generation: 9),
        ]

        for responseState in responses {
            let transport = ScriptedBackendTransport()
            let client = BackendProtocolClient(transport: transport)
            try await client.connect()
            let mutation = BackendProjectionNavigationMutation(
                logicalPresentationID: identifiers.logicalPresentationID,
                claimID: identifiers.claimID,
                expectedGeneration: 7,
                operations: []
            )
            let task = Task {
                try await client.mutateProjectionNavigationV2(
                    requestID: UUID(),
                    authority: authority,
                    expectedTopologyRevision: 41,
                    projections: [mutation]
                )
            }
            let request = try request(await transport.nextSent())
            await transport.enqueue(try response(
                to: request,
                data: appliedPayload(topologyRevision: 41, states: [responseState])
            ))
            await #expect(throws: BackendProtocolError.malformedMessage) {
                try await task.value
            }
            await client.close()
        }
    }

    @Test("list-all always begins without a cursor and consolidates one revision")
    func listAllPagination() async throws {
        let transport = ScriptedBackendTransport()
        let client = BackendProtocolClient(transport: transport)
        try await client.connect()
        let authority = try authority()
        let first = try identifiers()
        let second = try identifiers(
            logicalPresentationID: "22222222-2222-4222-8222-222222222222"
        )
        let cursor = BackendProjectionNavigationListCursor(
            clientRevision: 9,
            afterLogicalPresentationID: first.logicalPresentationID
        )

        let task = Task {
            try await client.listAllProjectionNavigationV2(
                authority: authority,
                expectedTopologyRevision: 41
            )
        }
        let firstRequest = try request(await transport.nextSent())
        #expect(firstRequest["cmd"] as? String == "list-projection-navigation-v2")
        #expect(firstRequest["cursor"] == nil)
        await transport.enqueue(try response(
            to: firstRequest,
            data: appliedPayload(
                topologyRevision: 41,
                clientRevision: 9,
                nextCursor: cursorPayload(cursor),
                states: [statePayload(identifiers: first, generation: 7)]
            )
        ))

        let secondRequest = try request(await transport.nextSent())
        let secondCursor = try #require(secondRequest["cursor"] as? [String: Any])
        #expect(try uint64(secondCursor, "client_revision") == 9)
        #expect(
            secondCursor["after_logical_presentation_id"] as? String
                == first.logicalPresentationID.uuidString.lowercased()
        )
        await transport.enqueue(try response(
            to: secondRequest,
            data: appliedPayload(
                topologyRevision: 41,
                clientRevision: 9,
                states: [statePayload(identifiers: second, generation: 3)]
            )
        ))

        guard case .applied(let page) = try await task.value else {
            Issue.record("expected a consolidated applied list")
            return
        }
        #expect(page.topologyRevision == 41)
        #expect(page.clientRevision == 9)
        #expect(page.nextCursor == nil)
        #expect(page.states.map(\.logicalPresentationID) == [
            first.logicalPresentationID,
            second.logicalPresentationID,
        ])
        await client.close()
    }

    @Test("list-all discards partial pages and restarts from nil after cursor conflicts")
    func listAllRestarts() async throws {
        let transport = ScriptedBackendTransport()
        let client = BackendProtocolClient(transport: transport)
        try await client.connect()
        let authority = try authority()
        let first = try identifiers()
        let replacement = try identifiers(
            logicalPresentationID: "33333333-3333-4333-8333-333333333333"
        )
        let cursor = BackendProjectionNavigationListCursor(
            clientRevision: 4,
            afterLogicalPresentationID: first.logicalPresentationID
        )

        let task = Task {
            try await client.listAllProjectionNavigationV2(
                authority: authority,
                expectedTopologyRevision: 41
            )
        }
        let initial = try request(await transport.nextSent())
        #expect(initial["cursor"] == nil)
        await transport.enqueue(try response(
            to: initial,
            data: appliedPayload(
                topologyRevision: 41,
                clientRevision: 4,
                nextCursor: cursorPayload(cursor),
                states: [statePayload(identifiers: first, generation: 1)]
            )
        ))
        let stale = try request(await transport.nextSent())
        #expect(stale["cursor"] != nil)
        await transport.enqueue(try response(to: stale, data: [
            "status": "conflict",
            "conflict": [
                "code": "stale-list-cursor",
                "expected_client_revision": 4,
                "current_client_revision": 5,
            ],
        ]))

        let restarted = try request(await transport.nextSent())
        #expect(restarted["cursor"] == nil)
        await transport.enqueue(try response(
            to: restarted,
            data: appliedPayload(
                topologyRevision: 41,
                clientRevision: 5,
                states: [statePayload(identifiers: replacement, generation: 1)]
            )
        ))
        guard case .applied(let list) = try await task.value else {
            Issue.record("expected restarted list to apply")
            return
        }
        #expect(list.clientRevision == 5)
        #expect(list.states.map(\.logicalPresentationID) == [
            replacement.logicalPresentationID,
        ])
        await client.close()
    }

    @Test("list-all returns the third-attempt conflict without sending a fourth attempt")
    func listAllRestartBound() async throws {
        let transport = ScriptedBackendTransport()
        let client = BackendProtocolClient(transport: transport)
        try await client.connect()
        let authority = try authority()

        let task = Task {
            try await client.listAllProjectionNavigationV2(
                authority: authority,
                expectedTopologyRevision: 41
            )
        }
        for revision in UInt64(1) ... UInt64(3) {
            let request = try request(await transport.nextSent())
            #expect(request["cursor"] == nil)
            await transport.enqueue(try response(to: request, data: [
                "status": "conflict",
                "conflict": [
                    "code": "list-cursor-restart-required",
                    "current_client_revision": revision,
                ],
            ]))
        }
        guard case .conflict(.listCursorRestartRequired(let revision)) = try await task.value else {
            Issue.record("expected the bounded restart conflict")
            return
        }
        #expect(revision == 3)
        #expect(await transport.sentCount() == 0)
        await client.close()
    }

    @Test("raw list pages reject topology, client revision, duplicate ID, and cursor drift")
    func listPageValidation() async throws {
        let authority = try authority()
        let identifiers = try identifiers()
        var nilIdentityState = statePayload(identifiers: identifiers, generation: 1)
        var nilIdentityWorkspaces = try #require(
            nilIdentityState["workspaces"] as? [[String: Any]]
        )
        var nilIdentityScreens = try #require(
            nilIdentityWorkspaces[0]["screens"] as? [[String: Any]]
        )
        var nilIdentityPanes = try #require(
            nilIdentityScreens[0]["panes"] as? [[String: Any]]
        )
        let nilUUID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        nilIdentityPanes[0]["pane_uuid"] = nilUUID.uuidString
        nilIdentityScreens[0]["active_pane_uuid"] = nilUUID.uuidString
        nilIdentityScreens[0]["zoomed_pane_uuid"] = nilUUID.uuidString
        nilIdentityScreens[0]["panes"] = nilIdentityPanes
        nilIdentityWorkspaces[0]["screens"] = nilIdentityScreens
        nilIdentityState["workspaces"] = nilIdentityWorkspaces

        var divergentZoomState = statePayload(identifiers: identifiers, generation: 1)
        var divergentZoomWorkspaces = try #require(
            divergentZoomState["workspaces"] as? [[String: Any]]
        )
        var divergentZoomScreens = try #require(
            divergentZoomWorkspaces[0]["screens"] as? [[String: Any]]
        )
        var divergentZoomPanes = try #require(
            divergentZoomScreens[0]["panes"] as? [[String: Any]]
        )
        let secondPaneID = try uuid("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb2")
        let secondSurfaceID = try uuid("cccccccc-cccc-4ccc-8ccc-ccccccccccc2")
        divergentZoomPanes.append([
            "pane_uuid": secondPaneID.uuidString,
            "selected_surface_uuid": secondSurfaceID.uuidString,
        ])
        divergentZoomScreens[0]["zoomed_pane_uuid"] = secondPaneID.uuidString
        divergentZoomScreens[0]["panes"] = divergentZoomPanes
        divergentZoomWorkspaces[0]["screens"] = divergentZoomScreens
        divergentZoomState["workspaces"] = divergentZoomWorkspaces

        let oversizedPage = try (0 ..< 65).map { index in
            statePayload(
                identifiers: identifiers,
                generation: 1,
                logicalPresentationID: indexedUUID(index + 1)
            )
        }
        let scenarios: [(String, UInt64, UInt64?, [String: Any]?, [[String: Any]])] = [
            (
                "topology mismatch",
                42,
                1,
                nil,
                [statePayload(identifiers: identifiers, generation: 1)]
            ),
            (
                "missing client revision",
                41,
                nil,
                nil,
                [statePayload(identifiers: identifiers, generation: 1)]
            ),
            (
                "duplicate logical presentation",
                41,
                1,
                nil,
                [
                    statePayload(identifiers: identifiers, generation: 1),
                    statePayload(identifiers: identifiers, generation: 1),
                ]
            ),
            (
                "cursor does not name final state",
                41,
                1,
                [
                    "client_revision": 1,
                    "after_logical_presentation_id": UUID().uuidString,
                ],
                [statePayload(identifiers: identifiers, generation: 1)]
            ),
            (
                "nil canonical identity",
                41,
                1,
                nil,
                [nilIdentityState]
            ),
            (
                "zoomed pane differs from active pane",
                41,
                1,
                nil,
                [divergentZoomState]
            ),
            (
                "page exceeds per-client record bound",
                41,
                1,
                nil,
                oversizedPage
            ),
        ]

        for scenario in scenarios {
            let transport = ScriptedBackendTransport()
            let client = BackendProtocolClient(transport: transport)
            try await client.connect()
            let task = Task {
                try await client.listProjectionNavigationV2Page(
                    authority: authority,
                    expectedTopologyRevision: 41,
                    cursor: nil
                )
            }
            let request = try request(await transport.nextSent())
            await transport.enqueue(try response(
                to: request,
                data: appliedPayload(
                    topologyRevision: scenario.1,
                    clientRevision: scenario.2,
                    nextCursor: scenario.3,
                    states: scenario.4
                )
            ))
            await #expect(throws: BackendProtocolError.malformedMessage, scenario.0) {
                try await task.value
            }
            await client.close()
        }
    }

    @Test("continuation pages reject nonadvancing cursors and client revision changes")
    func continuationValidation() async throws {
        let authority = try authority()
        let identifiers = try identifiers(
            logicalPresentationID: "22222222-2222-4222-8222-222222222222"
        )
        let inputCursor = BackendProjectionNavigationListCursor(
            clientRevision: 8,
            afterLogicalPresentationID: try uuid("11111111-1111-4111-8111-111111111111")
        )
        let scenarios: [(String, UInt64, UUID)] = [
            ("client revision changed", 9, identifiers.logicalPresentationID),
            ("cursor did not advance", 8, inputCursor.afterLogicalPresentationID),
        ]
        for scenario in scenarios {
            let transport = ScriptedBackendTransport()
            let client = BackendProtocolClient(transport: transport)
            try await client.connect()
            let task = Task {
                try await client.listProjectionNavigationV2Page(
                    authority: authority,
                    expectedTopologyRevision: 41,
                    cursor: inputCursor
                )
            }
            let request = try request(await transport.nextSent())
            await transport.enqueue(try response(
                to: request,
                data: appliedPayload(
                    topologyRevision: 41,
                    clientRevision: scenario.1,
                    nextCursor: [
                        "client_revision": scenario.1,
                        "after_logical_presentation_id": scenario.2.uuidString,
                    ],
                    states: [statePayload(identifiers: identifiers, generation: 1)]
                )
            ))
            await #expect(throws: BackendProtocolError.malformedMessage, scenario.0) {
                try await task.value
            }
            await client.close()
        }
    }

    @Test("mutation policy requires v2 while retaining v1 compatibility")
    func mutationCapabilityPolicy() {
        let capabilities = BackendHandshakePolicy.terminalAuthorityV1.requiredCapabilities
        #expect(capabilities.contains("projection-state-reconnect-v1"))
        #expect(capabilities.contains("projection-navigation-v2"))
    }

    @Test("mutation rejects nil request, logical-presentation, and claim IDs before dispatch")
    func mutationRejectsNilIdentities() async throws {
        let transport = ScriptedBackendTransport()
        let client = BackendProtocolClient(transport: transport)
        try await client.connect()
        let authority = try authority()
        let identifiers = try identifiers()
        let nilID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        let scenarios = [
            (
                nilID,
                BackendProjectionNavigationMutation(
                    logicalPresentationID: identifiers.logicalPresentationID,
                    claimID: identifiers.claimID,
                    expectedGeneration: 1,
                    operations: []
                )
            ),
            (
                identifiers.requestID,
                BackendProjectionNavigationMutation(
                    logicalPresentationID: nilID,
                    claimID: identifiers.claimID,
                    expectedGeneration: 1,
                    operations: []
                )
            ),
            (
                identifiers.requestID,
                BackendProjectionNavigationMutation(
                    logicalPresentationID: identifiers.logicalPresentationID,
                    claimID: nilID,
                    expectedGeneration: 1,
                    operations: []
                )
            ),
        ]
        for scenario in scenarios {
            await #expect(throws: BackendProtocolError.malformedMessage) {
                try await client.mutateProjectionNavigationV2(
                    requestID: scenario.0,
                    authority: authority,
                    expectedTopologyRevision: 41,
                    projections: [scenario.1]
                )
            }
        }
        #expect(await transport.sentCount() == 0)
        await client.close()
    }

    @Test("v2 list is rejected locally in diagnostic mode because the daemon may promote state")
    func listIsNotReadOnly() async throws {
        let transport = ScriptedBackendTransport()
        let client = BackendProtocolClient(transport: transport)
        try await client.connect()
        let diagnostic = BackendReadOnlyCompatibility(
            clientProtocolRange: 8 ... 9,
            serverProtocolRange: 8 ... 8,
            negotiatedProtocol: 8,
            minimumReadWriteProtocol: 9,
            requiredCapabilities: BackendHandshakePolicy.terminalAuthorityV1.requiredCapabilities,
            missingCapabilities: [],
            reasons: [.protocolTooOld]
        )
        try await client.installCompatibility(.readOnly(diagnostic))

        do {
            _ = try await client.listAllProjectionNavigationV2(
                authority: try authority(),
                expectedTopologyRevision: 41
            )
            Issue.record("diagnostic connection dispatched a state-promoting v2 list")
        } catch let error as BackendProtocolError {
            guard case .mutationUnavailableInReadOnlyMode(
                let command,
                let compatibility
            ) = error else {
                Issue.record("unexpected diagnostic rejection: \(error)")
                return
            }
            #expect(command == "list-projection-navigation-v2")
            #expect(compatibility == diagnostic)
        }
        #expect(await transport.sentCount() == 0)
        await client.close()
    }

    private struct Identifiers {
        let logicalPresentationID: UUID
        let claimID: UUID
        let requestID: UUID
        let releaseRequestID: UUID
        let processInstanceID: UUID
        let workspaceID: WorkspaceID
        let secondWorkspaceID: WorkspaceID
        let screenID: ScreenID
        let paneID: PaneID
        let surfaceID: SurfaceID
    }

    private func authority() throws -> BackendAuthority {
        BackendAuthority(
            daemonInstanceID: DaemonInstanceID(
                rawValue: try uuid("dddddddd-dddd-4ddd-8ddd-dddddddddddd")
            ),
            sessionID: SessionID(
                rawValue: try uuid("eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee")
            )
        )
    }

    private func identifiers(
        logicalPresentationID: String = "11111111-1111-4111-8111-111111111111"
    ) throws -> Identifiers {
        Identifiers(
            logicalPresentationID: try uuid(logicalPresentationID),
            claimID: try uuid("44444444-4444-4444-8444-444444444444"),
            requestID: try uuid("55555555-5555-4555-8555-555555555555"),
            releaseRequestID: try uuid("66666666-6666-4666-8666-666666666666"),
            processInstanceID: try uuid("77777777-7777-4777-8777-777777777777"),
            workspaceID: WorkspaceID(
                rawValue: try uuid("88888888-8888-4888-8888-888888888888")
            ),
            secondWorkspaceID: WorkspaceID(
                rawValue: try uuid("99999999-9999-4999-8999-999999999999")
            ),
            screenID: ScreenID(
                rawValue: try uuid("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1")
            ),
            paneID: PaneID(
                rawValue: try uuid("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb1")
            ),
            surfaceID: SurfaceID(
                rawValue: try uuid("cccccccc-cccc-4ccc-8ccc-ccccccccccc1")
            )
        )
    }

    private func statePayload(
        identifiers: Identifiers,
        generation: UInt64,
        logicalPresentationID: UUID? = nil
    ) -> [String: Any] {
        [
            "schema_version": 2,
            "logical_presentation_id": (
                logicalPresentationID ?? identifiers.logicalPresentationID
            ).uuidString,
            "generation": generation,
            "claim_id": identifiers.claimID.uuidString,
            "claimed_process_instance_uuid": identifiers.processInstanceID.uuidString,
            "reconciled_topology_revision": 41,
            "selected_workspace_uuid": identifiers.workspaceID.description,
            "workspaces": [[
                "workspace_uuid": identifiers.workspaceID.description,
                "selected_screen_uuid": identifiers.screenID.description,
                "screens": [[
                    "screen_uuid": identifiers.screenID.description,
                    "active_pane_uuid": identifiers.paneID.description,
                    "zoomed_pane_uuid": identifiers.paneID.description,
                    "panes": [[
                        "pane_uuid": identifiers.paneID.description,
                        "selected_surface_uuid": identifiers.surfaceID.description,
                    ]],
                ]],
            ]],
        ]
    }

    private func appliedPayload(
        topologyRevision: UInt64,
        clientRevision: UInt64? = nil,
        nextCursor: [String: Any]? = nil,
        states: [[String: Any]]
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "status": "applied",
            "topology_revision": topologyRevision,
            "states": states,
        ]
        if let clientRevision {
            payload["client_revision"] = clientRevision
        }
        if let nextCursor {
            payload["next_cursor"] = nextCursor
        }
        return payload
    }

    private func cursorPayload(
        _ cursor: BackendProjectionNavigationListCursor
    ) -> [String: Any] {
        [
            "client_revision": cursor.clientRevision,
            "after_logical_presentation_id": cursor.afterLogicalPresentationID.uuidString,
        ]
    }

    private func expectAuthority(
        _ request: [String: Any],
        authority: BackendAuthority,
        topologyRevision: UInt64
    ) throws {
        #expect(
            request["daemon_instance_id"] as? String
                == authority.daemonInstanceID.description
        )
        #expect(request["session_id"] as? String == authority.sessionID.description)
        #expect(try uint64(request, "expected_topology_revision") == topologyRevision)
    }

    private func request(_ data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func response(to request: [String: Any], data: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "id": try uint64(request, "id"),
            "ok": true,
            "data": data,
        ])
    }

    private func uint64(_ object: [String: Any], _ key: String) throws -> UInt64 {
        try #require(object[key] as? NSNumber).uint64Value
    }

    private func uuid(_ string: String) throws -> UUID {
        try #require(UUID(uuidString: string))
    }

    private func indexedUUID(_ index: Int) throws -> UUID {
        try uuid(String(format: "00000000-0000-4000-8000-%012llx", UInt64(index)))
    }
}
