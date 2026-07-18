import CmuxTerminalBackend
import Foundation
import Testing

@Suite("Typed renderer backend commands")
struct BackendRendererCommandTests {
    private let daemonUUID = "11111111-1111-4111-8111-111111111111"
    private let workspaceUUID = "22222222-2222-4222-8222-222222222222"
    private let terminalUUID = "33333333-3333-4333-8333-333333333333"
    private let presentationUUID = "44444444-4444-4444-8444-444444444444"

    @Test("renderer attachment installs an exact process and presentation fence")
    func configureRendererPresentation() async throws {
        let transport = ScriptedBackendTransport()
        let client = BackendProtocolClient(transport: transport)
        try await client.connect()
        let presentationID = PresentationID(rawValue: try uuid(presentationUUID))
        let capability = Data((0..<32).map(UInt8.init))
        let config = BackendRendererPresentationConfiguration(
            width: 2400,
            height: 1600,
            backingScaleFactor: 2,
            columns: 120,
            rows: 40,
            pixelFormat: .bgra8Unorm,
            colorSpace: .displayP3,
            frameEndpointService: "com.cmux.test.frames",
            frameEndpointCapability: capability,
            resolvedConfigRevision: 9,
            resolvedConfig: Data("font-family = Menlo".utf8),
            focused: true,
            cursorBlinkVisible: false,
            preedit: "日本語",
            preeditSelectionStartUTF16: 1,
            preeditSelectionLengthUTF16: 1,
            preeditCaretUTF16: 2
        )

        let task = Task {
            try await client.configureRendererPresentation(
                id: presentationID,
                expectedGeneration: 7,
                configuration: config
            )
        }
        let request = try requestObject(await transport.nextSent())
        #expect(request["cmd"] as? String == "configure-renderer-presentation")
        #expect(request["presentation_id"] as? String == presentationUUID)
        #expect(try uint64(request, "expected_generation") == 7)
        #expect(try uint64(request, "width") == 2400)
        #expect(try uint64(request, "height") == 1600)
        #expect(try double(request, "backing_scale_factor") == 2)
        #expect(request["pixel_format"] as? String == "bgra8-unorm")
        #expect(request["color_space"] as? String == "display-p3")
        #expect(request["frame_endpoint_capability"] as? String == capability.base64EncodedString())
        #expect(request["resolved_config"] as? String == Data("font-family = Menlo".utf8).base64EncodedString())
        #expect(request["cursor_blink_visible"] as? Bool == false)
        #expect(request["preedit"] as? String == "日本語")
        #expect(try uint64(request, "preedit_selection_start_utf16") == 1)
        #expect(try uint64(request, "preedit_selection_length_utf16") == 1)
        #expect(try uint64(request, "preedit_caret_utf16") == 2)

        await transport.enqueue(try response(to: request, data: [
            "daemon_instance_id": daemonUUID,
            "workspace_uuid": workspaceUUID,
            "renderer_epoch": 5,
            "worker_state": "ready",
            "worker_pid": 4321,
            "worker_effective_user_id": 501,
            "scene_capabilities": 3,
            "terminal_id": terminalUUID,
            "terminal_epoch": 2,
            "presentation_id": presentationUUID,
            "generation": 7,
            "renderer_generation": 8,
            "minimum_content_sequence": 21,
            "width": 2400,
            "height": 1600,
            "backing_scale_factor": 2,
            "columns": 120,
            "rows": 40,
            "metrics": NSNull(),
            "pixel_format": "bgra8-unorm",
            "color_space": "display-p3",
        ]))

        let receipt = try await task.value
        #expect(receipt.daemonInstanceID.description == daemonUUID)
        #expect(receipt.workerState == .ready)
        #expect(receipt.workerProcessID == 4321)
        #expect(receipt.workerEffectiveUserID == 501)
        #expect(receipt.terminalID.description == terminalUUID)
        #expect(receipt.rendererGeneration == 8)
        #expect(receipt.minimumContentSequence == 21)
        #expect(receipt.metrics == nil)
        await client.close()
    }

    @Test("renderer lifecycle and terminal mouse preserve exact generation fields")
    func rendererLifecycleAndMouse() async throws {
        let transport = ScriptedBackendTransport()
        let client = BackendProtocolClient(transport: transport)
        try await client.connect()
        let daemonID = DaemonInstanceID(rawValue: try uuid(daemonUUID))
        let terminalID = SurfaceID(rawValue: try uuid(terminalUUID))
        let presentationID = PresentationID(rawValue: try uuid(presentationUUID))

        let preeditTask = Task {
            try await client.setTerminalPreedit(
                presentationID: presentationID,
                rendererGeneration: 8,
                preedit: BackendTerminalPreedit(
                    text: "日本語",
                    selectionStartUTF16: 1,
                    selectionLengthUTF16: 1,
                    caretUTF16: 2
                )
            )
        }
        let preedit = try requestObject(await transport.nextSent())
        #expect(preedit["cmd"] as? String == "terminal-preedit")
        #expect(preedit["text"] as? String == "日本語")
        #expect(try uint64(preedit, "selection_start_utf16") == 1)
        #expect(try uint64(preedit, "selection_length_utf16") == 1)
        #expect(try uint64(preedit, "caret_utf16") == 2)
        await transport.enqueue(try response(to: preedit, data: [:]))
        try await preeditTask.value

        let releaseTask = Task {
            try await client.releaseRendererFrame(BackendRendererFrameRelease(
                daemonInstanceID: daemonID,
                rendererEpoch: 5,
                terminalID: terminalID,
                terminalEpoch: 2,
                terminalSequence: 22,
                presentationID: presentationID,
                presentationGeneration: 8,
                frameSequence: 13,
                surfaceID: 71
            ))
        }
        let release = try requestObject(await transport.nextSent())
        #expect(release["cmd"] as? String == "release-renderer-frame")
        #expect(release["daemon_instance_id"] as? String == daemonUUID)
        #expect(try uint64(release, "terminal_sequence") == 22)
        #expect(try uint64(release, "presentation_generation") == 8)
        #expect(try uint64(release, "frame_sequence") == 13)
        #expect(try uint64(release, "surface_id") == 71)
        await transport.enqueue(try response(to: release, data: ["forwarded": true]))
        #expect(try await releaseTask.value.forwarded)

        let workersTask = Task { try await client.rendererWorkers() }
        let workers = try requestObject(await transport.nextSent())
        #expect(workers["cmd"] as? String == "renderer-workers")
        await transport.enqueue(try response(to: workers, data: [
            "daemon_instance_id": daemonUUID,
            "workers": [[
                "workspace_uuid": workspaceUUID,
                "renderer_epoch": 5,
                "pid": 4321,
                "effective_user_id": 501,
                "scene_capabilities": 3,
                "restart_count": 1,
                "visible_presentation_count": 2,
                "state": "ready",
                "retry_after_milliseconds": NSNull(),
                "last_error": NSNull(),
            ]],
        ]))
        let census = try await workersTask.value
        #expect(census.workers.count == 1)
        #expect(census.workers[0].processID == 4321)
        #expect(census.workers[0].visiblePresentationCount == 2)

        let mouseTask = Task {
            try await client.sendTerminalMouse(
                surface: 41,
                event: BackendTerminalMouseEvent(
                    action: .press,
                    button: .left,
                    modifiers: 3,
                    x: 17.5,
                    y: 29.25,
                    viewportWidth: 2400,
                    viewportHeight: 1600,
                    cellWidth: 20,
                    cellHeight: 40,
                    padding: BackendRendererPadding(left: 8, top: 12),
                    anyButtonPressed: true
                )
            )
        }
        let mouse = try requestObject(await transport.nextSent())
        #expect(mouse["cmd"] as? String == "terminal-mouse")
        #expect(mouse["action"] as? String == "press")
        #expect(mouse["button"] as? String == "left")
        #expect(try double(mouse, "x") == 17.5)
        #expect(try uint64(mouse, "padding_left") == 8)
        #expect(mouse["any_button_pressed"] as? Bool == true)
        #expect(try uint64(mouse, "click_count") == 1)
        await transport.enqueue(try response(to: mouse, data: [
            "encoded_bytes": 6,
            "route": "selection",
        ]))
        let mouseResponse = try await mouseTask.value
        #expect(mouseResponse.encodedBytes == 6)
        #expect(mouseResponse.route == .selection)

        let scrollbackResponse = try JSONDecoder().decode(
            BackendTerminalMouseResponse.self,
            from: Data(#"{"encoded_bytes":0,"route":"scrollback"}"#.utf8)
        )
        #expect(scrollbackResponse.route == .scrollback)

        let detachTask = Task {
            try await client.detachRendererPresentation(id: presentationID, expectedGeneration: 7)
        }
        let detach = try requestObject(await transport.nextSent())
        #expect(detach["cmd"] as? String == "detach-renderer-presentation")
        #expect(try uint64(detach, "expected_generation") == 7)
        await transport.enqueue(try response(to: detach, data: [:]))
        try await detachTask.value
        await client.close()
    }

    private func uuid(_ value: String) throws -> UUID {
        try #require(UUID(uuidString: value))
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

    private func double(_ object: [String: Any], _ key: String) throws -> Double {
        try #require(object[key] as? NSNumber).doubleValue
    }
}
