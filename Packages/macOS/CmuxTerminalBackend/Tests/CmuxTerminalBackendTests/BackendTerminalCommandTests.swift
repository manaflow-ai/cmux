import CmuxTerminalBackend
import Foundation
import Testing

@Suite("Typed terminal backend commands")
struct BackendTerminalCommandTests {
    @Test("ensure terminal carries stable identity and creation-only launch fields")
    func ensureTerminalStableIdentity() async throws {
        let transport = ScriptedBackendTransport()
        let client = BackendProtocolClient(transport: transport)
        try await client.connect()
        let workspaceID = WorkspaceID(
            rawValue: try #require(UUID(uuidString: "11111111-1111-4111-8111-111111111111"))
        )
        let surfaceID = SurfaceID(
            rawValue: try #require(UUID(uuidString: "22222222-2222-4222-8222-222222222222"))
        )

        let task = Task {
            try await client.ensureTerminal(
                workspaceID: workspaceID,
                surfaceID: surfaceID,
                workingDirectory: "/tmp/project",
                arguments: ["/bin/zsh", "-l"],
                environment: ["Z_LAST": "2", "A_FIRST": "1"],
                initialInput: "printf ready\n",
                waitAfterCommand: true,
                columns: 132,
                rows: 43
            )
        }
        let request = try requestObject(await transport.nextSent())
        #expect(request["cmd"] as? String == "ensure-terminal")
        #expect(request["workspace_uuid"] as? String == workspaceID.description)
        #expect(request["surface_uuid"] as? String == surfaceID.description)
        #expect(request["cwd"] as? String == "/tmp/project")
        #expect(request["argv"] as? [String] == ["/bin/zsh", "-l"])
        #expect(request["initial_input"] as? String == "printf ready\n")
        #expect(request["wait_after_command"] as? Bool == true)
        #expect(try uint64(request, "cols") == 132)
        #expect(try uint64(request, "rows") == 43)
        let environment = try #require(request["env"] as? [[String: String]])
        #expect(environment == [
            ["name": "A_FIRST", "value": "1"],
            ["name": "Z_LAST", "value": "2"],
        ])

        let screenID = "33333333-3333-4333-8333-333333333333"
        let paneID = "44444444-4444-4444-8444-444444444444"
        await transport.enqueue(try response(
            to: request,
            data: [
                "created": false,
                "workspace": 11,
                "workspace_uuid": workspaceID.description,
                "screen": 21,
                "screen_uuid": screenID,
                "pane": 31,
                "pane_uuid": paneID,
                "surface": 41,
                "surface_uuid": surfaceID.description,
            ]
        ))

        let placement = try await task.value
        #expect(placement.created == false)
        #expect(placement.workspace == 11)
        #expect(placement.workspaceID == workspaceID)
        #expect(placement.screen == 21)
        #expect(placement.screenID.description == screenID)
        #expect(placement.pane == 31)
        #expect(placement.paneID.description == paneID)
        #expect(placement.surface == 41)
        #expect(placement.surfaceID == surfaceID)
        await client.close()
    }

    @Test("ensure terminals sends one ordered bounded batch command")
    func ensureTerminalsBatch() async throws {
        let transport = ScriptedBackendTransport()
        let client = BackendProtocolClient(transport: transport)
        try await client.connect()
        let workspaceIDs = [
            WorkspaceID(rawValue: UUID()),
            WorkspaceID(rawValue: UUID()),
        ]
        let surfaceIDs = [
            SurfaceID(rawValue: UUID()),
            SurfaceID(rawValue: UUID()),
        ]
        let task = Task {
            try await client.ensureTerminals(zip(workspaceIDs, surfaceIDs).map { identity in
                BackendEnsureTerminalRequest(
                    workspaceID: identity.0,
                    surfaceID: identity.1,
                    arguments: ["/bin/sh"],
                    columns: 90,
                    rows: 30
                )
            })
        }
        let request = try requestObject(await transport.nextSent())
        #expect(request["cmd"] as? String == "ensure-terminals")
        let terminals = try #require(request["terminals"] as? [[String: Any]])
        #expect(terminals.count == 2)
        #expect(terminals[0]["workspace_uuid"] as? String == workspaceIDs[0].description)
        #expect(terminals[0]["surface_uuid"] as? String == surfaceIDs[0].description)
        #expect(terminals[1]["workspace_uuid"] as? String == workspaceIDs[1].description)
        #expect(terminals[1]["surface_uuid"] as? String == surfaceIDs[1].description)

        let data = zip(workspaceIDs, surfaceIDs).enumerated().map { entry in
            let (index, identity) = entry
            return [
                "created": true,
                "workspace": 10 + index,
                "workspace_uuid": identity.0.description,
                "screen": 20 + index,
                "screen_uuid": UUID().uuidString,
                "pane": 30 + index,
                "pane_uuid": UUID().uuidString,
                "surface": 40 + index,
                "surface_uuid": identity.1.description,
            ] as [String: Any]
        }
        await transport.enqueue(try response(to: request, data: data))

        let placements = try await task.value
        #expect(placements.count == 2)
        #expect(placements[0].workspaceID == workspaceIDs[0])
        #expect(placements[0].surfaceID == surfaceIDs[0])
        #expect(placements[1].workspaceID == workspaceIDs[1])
        #expect(placements[1].surfaceID == surfaceIDs[1])
        await client.close()
    }

    @Test("reparent terminal preserves stable surface identity and returns full placement")
    func reparentTerminalStableIdentity() async throws {
        let transport = ScriptedBackendTransport()
        let client = BackendProtocolClient(transport: transport)
        try await client.connect()
        let workspaceID = WorkspaceID(
            rawValue: try #require(UUID(uuidString: "55555555-5555-4555-8555-555555555555"))
        )
        let surfaceID = SurfaceID(
            rawValue: try #require(UUID(uuidString: "22222222-2222-4222-8222-222222222222"))
        )

        let task = Task {
            try await client.reparentTerminal(surfaceID: surfaceID, workspaceID: workspaceID)
        }
        let request = try requestObject(await transport.nextSent())
        #expect(request["cmd"] as? String == "reparent-terminal")
        #expect(request["surface_uuid"] as? String == surfaceID.description)
        #expect(request["workspace_uuid"] as? String == workspaceID.description)
        let screenID = "66666666-6666-4666-8666-666666666666"
        let paneID = "77777777-7777-4777-8777-777777777777"
        await transport.enqueue(try response(
            to: request,
            data: [
                "moved": true,
                "workspace": 51,
                "workspace_uuid": workspaceID.description,
                "screen": 61,
                "screen_uuid": screenID,
                "pane": 71,
                "pane_uuid": paneID,
                "surface": 41,
                "surface_uuid": surfaceID.description,
            ]
        ))

        let placement = try await task.value
        #expect(placement.moved)
        #expect(placement.workspace == 51)
        #expect(placement.workspaceID == workspaceID)
        #expect(placement.screen == 61)
        #expect(placement.screenID.description == screenID)
        #expect(placement.pane == 71)
        #expect(placement.paneID.description == paneID)
        #expect(placement.surface == 41)
        #expect(placement.surfaceID == surfaceID)
        await client.close()
    }

    @Test("workspace creation decodes the complete canonical placement")
    func workspaceCreationPlacement() async throws {
        let transport = ScriptedBackendTransport()
        let client = BackendProtocolClient(transport: transport)
        try await client.connect()

        let daemonID = DaemonInstanceID(rawValue: try #require(UUID(
            uuidString: "10101010-1010-4010-8010-101010101010"
        )))
        let sessionID = SessionID(rawValue: try #require(UUID(
            uuidString: "20202020-2020-4020-8020-202020202020"
        )))
        let workspaceID = WorkspaceID(rawValue: try #require(UUID(
            uuidString: "30303030-3030-4030-8030-303030303030"
        )))
        let surfaceID = SurfaceID(rawValue: try #require(UUID(
            uuidString: "40404040-4040-4040-8040-404040404040"
        )))
        let requestID = try #require(UUID(uuidString: "50505050-5050-4050-8050-505050505050"))
        let expectation = BackendTopologyMutationExpectation(
            requestID: requestID,
            authority: BackendAuthority(daemonInstanceID: daemonID, sessionID: sessionID),
            revision: 7
        )
        let task = Task {
            try await client.canonicalNewWorkspace(
                expectation: expectation,
                workspaceID: workspaceID,
                surfaceID: surfaceID,
                name: "agents",
                columns: 132,
                rows: 43
            )
        }
        let request = try requestObject(await transport.nextSent())
        #expect(request["cmd"] as? String == "canonical-new-workspace")
        #expect(request["request_id"] as? String == requestID.uuidString.lowercased())
        #expect(request["daemon_instance_id"] as? String == daemonID.description)
        #expect(request["session_id"] as? String == sessionID.description)
        #expect(try uint64(request, "expected_revision") == 7)
        #expect(request["workspace_uuid"] as? String == workspaceID.description)
        #expect(request["surface_uuid"] as? String == surfaceID.description)
        #expect(request["name"] as? String == "agents")
        #expect(try uint64(request, "cols") == 132)
        #expect(try uint64(request, "rows") == 43)
        await transport.enqueue(try response(
            to: request,
            data: [
                "request_id": requestID.uuidString,
                "daemon_instance_id": daemonID.description,
                "session_id": sessionID.description,
                "base_revision": 7,
                "revision": 8,
                "replayed": false,
                "surface": 41,
                "surface_uuid": surfaceID.description,
                "pane": 31,
                "pane_uuid": "60606060-6060-4060-8060-606060606060",
                "screen": 21,
                "screen_uuid": "70707070-7070-4070-8070-707070707070",
                "workspace": 11,
                "workspace_uuid": workspaceID.description,
            ]
        ))

        let placement = try await task.value
        #expect(placement.surface == 41)
        #expect(placement.pane == 31)
        #expect(placement.screen == 21)
        #expect(placement.workspace == 11)
        #expect(placement.receipt.revision == 8)
        await client.close()
    }

    @Test("semantic key command preserves Ghostty key fields")
    func semanticKeyCommand() async throws {
        let transport = ScriptedBackendTransport()
        let client = BackendProtocolClient(transport: transport)
        try await client.connect()
        let event = BackendTerminalKeyEvent(
            key: 117,
            modifiers: 0x21,
            consumedModifiers: 0x20,
            text: "A",
            unshiftedCodepoint: 97,
            action: .repeat
        )

        let task = Task { try await client.sendTerminalKey(surface: 41, event: event) }
        let request = try requestObject(await transport.nextSent())
        #expect(request["cmd"] as? String == "terminal-key")
        #expect(try uint64(request, "surface") == 41)
        #expect(try uint64(request, "key") == 117)
        #expect(try uint64(request, "modifiers") == 0x21)
        #expect(try uint64(request, "consumed_modifiers") == 0x20)
        #expect(request["text"] as? String == "A")
        #expect(try uint64(request, "unshifted_codepoint") == 97)
        #expect(request["action"] as? String == "repeat")
        await transport.enqueue(try response(to: request, data: ["encoded_bytes": 3]))

        #expect(try await task.value.encodedBytes == 3)

        let namedTask = Task {
            try await client.sendTerminalNamedKey(surface: 41, key: "ctrl+shift+enter")
        }
        let named = try requestObject(await transport.nextSent())
        #expect(named["cmd"] as? String == "send-key")
        #expect(try uint64(named, "surface") == 41)
        #expect(named["keys"] as? [String] == ["ctrl+shift+enter"])
        await transport.enqueue(try response(to: named, data: [:]))
        try await namedTask.value
        await client.close()
    }

    @Test("terminal lifecycle helpers use the canonical surface")
    func lifecycleHelpers() async throws {
        let transport = ScriptedBackendTransport()
        let client = BackendProtocolClient(transport: transport)
        try await client.connect()

        let daemonID = DaemonInstanceID(rawValue: UUID())
        let sessionID = SessionID(rawValue: UUID())
        let paneID = PaneID(rawValue: UUID())
        let surfaceID = SurfaceID(rawValue: UUID())
        let expectation = BackendTopologyMutationExpectation(
            requestID: UUID(),
            authority: BackendAuthority(daemonInstanceID: daemonID, sessionID: sessionID),
            revision: 2
        )
        let tabTask = Task {
            try await client.canonicalNewTerminalTab(
                expectation: expectation,
                paneID: paneID,
                surfaceID: surfaceID,
                launch: BackendTerminalLaunch(workingDirectory: "/tmp/project"),
                columns: 80,
                rows: 24
            )
        }
        let tab = try requestObject(await transport.nextSent())
        #expect(tab["cmd"] as? String == "canonical-new-tab")
        #expect(tab["pane_uuid"] as? String == paneID.description)
        #expect(tab["cwd"] as? String == "/tmp/project")
        await transport.enqueue(try response(
            to: tab,
            data: [
                "request_id": expectation.requestID.uuidString,
                "daemon_instance_id": daemonID.description,
                "session_id": sessionID.description,
                "base_revision": 2,
                "revision": 3,
                "surface": 42,
                "surface_uuid": surfaceID.description,
                "pane": 31,
                "pane_uuid": paneID.description,
                "screen": 21,
                "screen_uuid": UUID().uuidString,
                "workspace": 11,
                "workspace_uuid": UUID().uuidString,
            ]
        ))
        #expect(try await tabTask.value.surface == 42)

        let textTask = Task { try await client.sendTerminalText(surface: 42, text: "hello", paste: true) }
        let text = try requestObject(await transport.nextSent())
        #expect(text["cmd"] as? String == "send")
        #expect(text["text"] as? String == "hello")
        #expect(text["paste"] as? Bool == true)
        await transport.enqueue(try response(to: text, data: [:]))
        try await textTask.value

        let resizeTask = Task { try await client.resizeTerminal(surface: 42, columns: 120, rows: 30) }
        let resize = try requestObject(await transport.nextSent())
        #expect(resize["cmd"] as? String == "resize-surface")
        #expect(try uint64(resize, "cols") == 120)
        #expect(try uint64(resize, "rows") == 30)
        await transport.enqueue(try response(
            to: resize,
            data: ["accepted": true, "reservation_id": 9]
        ))
        #expect(try await resizeTask.value.reservationID == 9)

        let scrollTask = Task { try await client.scrollTerminal(surface: 42, rowDelta: -5) }
        let scroll = try requestObject(await transport.nextSent())
        #expect(scroll["cmd"] as? String == "scroll-surface")
        #expect(try int64(scroll, "delta") == -5)
        await transport.enqueue(try response(to: scroll, data: [:]))
        try await scrollTask.value

        let screenTask = Task { try await client.readTerminalScreen(surface: 42) }
        let screen = try requestObject(await transport.nextSent())
        #expect(screen["cmd"] as? String == "read-screen")
        await transport.enqueue(try response(to: screen, data: ["text": "prompt"] ))
        #expect(try await screenTask.value.text == "prompt")

        let processTask = Task { try await client.terminalProcessInfo(surface: 42) }
        let process = try requestObject(await transport.nextSent())
        #expect(process["cmd"] as? String == "process-info")
        await transport.enqueue(try response(
            to: process,
            data: [
                "pid": 1234,
                "command": ["/bin/zsh", "-l"],
                "cwd": "/tmp/project",
                "tty": "/dev/ttys042",
            ]
        ))
        let processInfo = try await processTask.value
        #expect(processInfo.processID == 1234)
        #expect(processInfo.command == ["/bin/zsh", "-l"])
        #expect(processInfo.workingDirectory == "/tmp/project")
        #expect(processInfo.controllingTTYName == "/dev/ttys042")

        let closeTask = Task { try await client.closeTerminal(surface: 42) }
        let close = try requestObject(await transport.nextSent())
        #expect(close["cmd"] as? String == "close-surface")
        #expect(try uint64(close, "surface") == 42)
        await transport.enqueue(try response(to: close, data: [:]))
        try await closeTask.value
        await client.close()
    }

    @Test("terminal UX commands decode canonical cursor state and encode copy mode")
    func terminalUXCommands() async throws {
        let transport = ScriptedBackendTransport()
        let client = BackendProtocolClient(transport: transport)
        try await client.connect()
        let surfaceID = SurfaceID(
            rawValue: try #require(UUID(uuidString: "22222222-2222-4222-8222-222222222222"))
        )
        let stateJSON: [String: Any] = [
            "surface_uuid": surfaceID.description,
            "copy_mode": false,
            "copy_cursor": NSNull(),
            "cursor": ["column": 7, "row": 42, "visible": true],
            "selection": [
                "has_selection": false,
                "text": NSNull(),
                "range": NSNull(),
            ],
            "search": [
                "active": false,
                "query": "",
                "selected_match": NSNull(),
                "total_matches": 0,
            ],
            "viewport": ["total_rows": 100, "offset": 20, "visible_rows": 24],
            "mouse_tracking": true,
        ]

        let stateTask = Task { try await client.terminalState(surfaceID: surfaceID) }
        let stateRequest = try requestObject(await transport.nextSent())
        #expect(stateRequest["cmd"] as? String == "terminal-state")
        await transport.enqueue(try response(to: stateRequest, data: stateJSON))
        let state = try await stateTask.value.state
        #expect(state.cursor?.column == 7)
        #expect(state.cursor?.row == 42)
        #expect(state.mouseTracking)
        #expect(state.selection?.hasSelection == false)
        #expect(state.selection?.text == nil)

        let copyTask = Task {
            try await client.terminalCopyMode(
                surfaceID: surfaceID,
                operation: .startLineSelection,
                count: 3
            )
        }
        let copyRequest = try requestObject(await transport.nextSent())
        #expect(copyRequest["cmd"] as? String == "terminal-copy-mode")
        #expect(copyRequest["operation"] as? String == "start-line-selection")
        #expect(try uint64(copyRequest, "count") == 3)
        await transport.enqueue(try response(to: copyRequest, data: [
            "handled": true,
            "clipboard_text": NSNull(),
            "state": stateJSON,
        ]))
        #expect(try await copyTask.value.handled)
        await client.close()
    }

    @Test("terminal accessibility preserves UTF-16 mappings and revision-fenced links")
    func terminalAccessibilityCommands() async throws {
        let transport = ScriptedBackendTransport()
        let client = BackendProtocolClient(transport: transport)
        try await client.connect()
        let presentationID = PresentationID(
            rawValue: try #require(UUID(uuidString: "88888888-8888-4888-8888-888888888888"))
        )
        let surfaceID = SurfaceID(
            rawValue: try #require(UUID(uuidString: "22222222-2222-4222-8222-222222222222"))
        )

        let snapshotTask = Task {
            try await client.terminalAccessibilitySnapshot(
                presentationID: presentationID,
                expectedGeneration: 7,
                expectedContentSequence: 13
            )
        }
        let snapshotRequest = try requestObject(await transport.nextSent())
        #expect(snapshotRequest["cmd"] as? String == "terminal-accessibility-snapshot")
        #expect(snapshotRequest["presentation_id"] as? String == presentationID.description)
        #expect(try uint64(snapshotRequest, "expected_generation") == 7)
        #expect(try uint64(snapshotRequest, "expected_content_sequence") == 13)
        await transport.enqueue(try response(to: snapshotRequest, data: [
            "schema_version": 1,
            "surface_uuid": surfaceID.description,
            "presentation_id": presentationID.description,
            "presentation_generation": 7,
            "content_sequence": 13,
            "terminal_revision": 11,
            "content_revision": 9,
            "viewport_revision": 3,
            "viewport_offset": 40,
            "columns": 8,
            "rows": 2,
            "text": "🙂e\u{301}界\nlink",
            "lines": [
                [
                    "row": 40,
                    "utf16_range": ["location": 0, "length": 5],
                    "cells": [
                        [
                            "column": 0,
                            "column_span": 2,
                            "utf16_range": ["location": 0, "length": 2],
                        ],
                        [
                            "column": 2,
                            "column_span": 1,
                            "utf16_range": ["location": 2, "length": 2],
                        ],
                        [
                            "column": 3,
                            "column_span": 2,
                            "utf16_range": ["location": 4, "length": 1],
                        ],
                    ],
                ],
                [
                    "row": 41,
                    "utf16_range": ["location": 6, "length": 4],
                    "cells": (0 ..< 4).map { column in
                        [
                            "column": column,
                            "column_span": 1,
                            "utf16_range": ["location": 6 + column, "length": 1],
                        ]
                    },
                ],
            ],
            "cursor": [
                "column": 2,
                "row": 40,
                "insertion_range": ["location": 2, "length": 0],
                "line": 0,
            ],
            "selections": [[
                "text": "e\u{301}界\nlink",
                "utf16_ranges": [
                    ["location": 2, "length": 3],
                    ["location": 6, "length": 4],
                ],
            ]],
            "links": [[
                "id": "9:3:feedface",
                "target": "https://example.com/a",
                "utf16_range": ["location": 6, "length": 4],
                "row": 41,
                "start_column": 0,
                "end_column": 3,
            ]],
            "focused": true,
        ]))

        let snapshot = try await snapshotTask.value
        #expect(snapshot.contentSequence == 13)
        #expect(snapshot.text == "🙂e\u{301}界\nlink")
        #expect(snapshot.lines[0].cells[0].utf16Range.length == 2)
        #expect(snapshot.lines[0].cells[1].utf16Range.length == 2)
        #expect(snapshot.lines[1].utf16Range.location == 6)
        #expect(snapshot.selections[0].utf16Ranges.count == 2)
        #expect(snapshot.cursor?.insertionRange.location == 2)
        #expect(snapshot.links[0].id == "9:3:feedface")
        #expect(snapshot.focused)

        let activationTask = Task {
            try await client.activateTerminalAccessibilityLink(
                presentationID: presentationID,
                expectedGeneration: 7,
                terminalRevision: 11,
                contentRevision: 9,
                viewportRevision: 3,
                linkID: "9:3:feedface"
            )
        }
        let activationRequest = try requestObject(await transport.nextSent())
        #expect(activationRequest["cmd"] as? String == "terminal-accessibility-activate-link")
        #expect(try uint64(activationRequest, "terminal_revision") == 11)
        #expect(try uint64(activationRequest, "content_revision") == 9)
        #expect(try uint64(activationRequest, "viewport_revision") == 3)
        #expect(activationRequest["link_id"] as? String == "9:3:feedface")
        await transport.enqueue(try response(
            to: activationRequest,
            data: ["target": "https://example.com/a"]
        ))
        #expect(try await activationTask.value.target == "https://example.com/a")
        await client.close()
    }

    private func requestObject(_ data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func response(to request: [String: Any], data: Any) throws -> Data {
        try encodedJSON([
            "id": try uint64(request, "id"),
            "ok": true,
            "data": data,
        ])
    }

    private func uint64(_ object: [String: Any], _ key: String) throws -> UInt64 {
        try #require(object[key] as? NSNumber).uint64Value
    }

    private func int64(_ object: [String: Any], _ key: String) throws -> Int64 {
        try #require(object[key] as? NSNumber).int64Value
    }
}
