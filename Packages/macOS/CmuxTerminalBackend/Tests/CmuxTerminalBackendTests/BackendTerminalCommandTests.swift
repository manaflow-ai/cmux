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

        let task = Task {
            try await client.newWorkspace(name: "agents", columns: 132, rows: 43)
        }
        let request = try requestObject(await transport.nextSent())
        #expect(request["cmd"] as? String == "new-workspace")
        #expect(request["name"] as? String == "agents")
        #expect(try uint64(request, "cols") == 132)
        #expect(try uint64(request, "rows") == 43)
        await transport.enqueue(try response(
            to: request,
            data: ["surface": 41, "pane": 31, "screen": 21, "workspace": 11]
        ))

        let placement = try await task.value
        #expect(placement.surface == 41)
        #expect(placement.pane == 31)
        #expect(placement.screen == 21)
        #expect(placement.workspace == 11)
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

        let tabTask = Task {
            try await client.newTerminalTab(
                pane: 31,
                workingDirectory: "/tmp/project",
                columns: 80,
                rows: 24
            )
        }
        let tab = try requestObject(await transport.nextSent())
        #expect(tab["cmd"] as? String == "new-tab")
        #expect(try uint64(tab, "pane") == 31)
        #expect(tab["cwd"] as? String == "/tmp/project")
        await transport.enqueue(try response(
            to: tab,
            data: ["surface": 42, "pane": 31, "screen": 21, "workspace": 11]
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

    private func requestObject(_ data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func response(to request: [String: Any], data: [String: Any]) throws -> Data {
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
