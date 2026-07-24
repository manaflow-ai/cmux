import CMUXMobileCore
import CmuxMobileRPC
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Suite struct MobileShellWorkspaceMetadataActionTests {
    @Test func descriptionActionsSendExactWorkspaceActionParams() async throws {
        let capture = WorkspaceMetadataActionCapture()
        let store = try await connectedMetadataStore(capture: capture)
        let workspaceID = try #require(store.workspaces.first?.id)

        guard case .success = await store.setWorkspaceDescription(
            id: workspaceID,
            "  Release\r\nvalidation  "
        ) else {
            return #expect(Bool(false), "setting a description should succeed")
        }
        guard case .success = await store.setWorkspaceDescription(id: workspaceID, " \n ") else {
            return #expect(Bool(false), "clearing a description should succeed")
        }

        let requests = await capture.requests()
        #expect(requests == [
            WorkspaceMetadataActionRequest(
                method: "workspace.action",
                stringParams: [
                    "workspace_id": "live-workspace",
                    "client_id": store.clientID,
                    "action": "set_description",
                    "description": "  Release\nvalidation  ",
                ],
                paramCount: 4,
                nonStringParamKeys: []
            ),
            WorkspaceMetadataActionRequest(
                method: "workspace.action",
                stringParams: [
                    "workspace_id": "live-workspace",
                    "client_id": store.clientID,
                    "action": "clear_description",
                ],
                paramCount: 3,
                nonStringParamKeys: []
            ),
        ])
    }

    @Test func descriptionActionBoundsPayloadBeforeSendingToMac() async throws {
        let capture = WorkspaceMetadataActionCapture()
        let store = try await connectedMetadataStore(capture: capture)
        let workspaceID = try #require(store.workspaces.first?.id)

        guard case .success = await store.setWorkspaceDescription(
            id: workspaceID,
            String(repeating: "🧪", count: 2_000)
        ) else {
            return #expect(Bool(false), "setting a long description should succeed")
        }

        let request = try #require(await capture.requests().first)
        let description = try #require(request.stringParams["description"])
        #expect(
            description.utf8.count == MobileWorkspaceMetadataLimits.customDescriptionMaxUTF8Bytes
        )
    }

    @Test func colorActionsSendExactWorkspaceActionParams() async throws {
        let capture = WorkspaceMetadataActionCapture()
        let store = try await connectedMetadataStore(capture: capture)
        let workspaceID = try #require(store.workspaces.first?.id)

        guard case .success = await store.setWorkspaceColor(id: workspaceID, "  #1565C0  ") else {
            return #expect(Bool(false), "setting a color should succeed")
        }
        guard case .success = await store.setWorkspaceColor(id: workspaceID, nil) else {
            return #expect(Bool(false), "clearing a color should succeed")
        }

        let requests = await capture.requests()
        #expect(requests == [
            WorkspaceMetadataActionRequest(
                method: "workspace.action",
                stringParams: [
                    "workspace_id": "live-workspace",
                    "client_id": store.clientID,
                    "action": "set_color",
                    "color": "#1565C0",
                ],
                paramCount: 4,
                nonStringParamKeys: []
            ),
            WorkspaceMetadataActionRequest(
                method: "workspace.action",
                stringParams: [
                    "workspace_id": "live-workspace",
                    "client_id": store.clientID,
                    "action": "clear_color",
                ],
                paramCount: 3,
                nonStringParamKeys: []
            ),
        ])
    }

    private func connectedMetadataStore(
        capture: WorkspaceMetadataActionCapture
    ) async throws -> MobileShellComposite {
        let router = LivenessHostRouter()
        await router.setCapabilities([
            "events.v1",
            "terminal.render_grid.v1",
            "terminal.replay.v1",
            "workspace.actions.v1",
            "workspace.metadata.v1",
        ])
        let clock = TestClock()
        let runtime = LivenessTestRuntime(
            transportFactory: WorkspaceMetadataActionTransportFactory(
                router: router,
                capture: capture
            ),
            now: { clock.now }
        )
        let store = MobileShellComposite.preview(runtime: runtime)
        store.signIn()
        let connected = await store.connectPairingURL(try attachURL(for: makeTicket(clock: clock)))
        #expect(connected, "scripted connect must succeed")
        let metadataResolved = try await pollUntil {
            store.supportsWorkspaceMetadata
                && store.workspaces.first?.actionCapabilities.supportsWorkspaceMetadata == true
        }
        #expect(metadataResolved, "workspace metadata capability must reach the projected row")
        return store
    }
}

private struct WorkspaceMetadataActionRequest: Equatable, Sendable {
    var method: String
    var stringParams: [String: String]
    var paramCount: Int
    var nonStringParamKeys: [String]
}

private actor WorkspaceMetadataActionCapture {
    private var recorded: [WorkspaceMetadataActionRequest] = []

    func record(_ request: WorkspaceMetadataActionRequest) {
        recorded.append(request)
    }

    func requests() -> [WorkspaceMetadataActionRequest] {
        recorded
    }
}

private struct WorkspaceMetadataActionTransportFactory: CmxByteTransportFactory {
    let router: LivenessHostRouter
    let capture: WorkspaceMetadataActionCapture

    func makeTransport(for _: CmxAttachRoute) throws -> any CmxByteTransport {
        WorkspaceMetadataActionTransport(
            base: LivenessTransport(router: router),
            capture: capture
        )
    }
}

private actor WorkspaceMetadataActionTransport: CmxByteTransport {
    let base: LivenessTransport
    let capture: WorkspaceMetadataActionCapture

    init(base: LivenessTransport, capture: WorkspaceMetadataActionCapture) {
        self.base = base
        self.capture = capture
    }

    func connect() async throws {
        try await base.connect()
    }

    func receive() async throws -> Data? {
        try await base.receive()
    }

    func send(_ data: Data) async throws {
        var buffer = data
        let payloads = try MobileSyncFrameCodec.decodeFrames(from: &buffer)
        guard payloads.count == 1,
              let payload = payloads.first,
              let request = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
              request["method"] as? String == "workspace.action",
              let id = request["id"] as? String,
              let params = request["params"] as? [String: Any] else {
            try await base.send(data)
            return
        }

        let stringParams = params.compactMapValues { $0 as? String }
        await capture.record(WorkspaceMetadataActionRequest(
            method: "workspace.action",
            stringParams: stringParams,
            paramCount: params.count,
            nonStringParamKeys: params.keys.filter { stringParams[$0] == nil }.sorted()
        ))

        let response = try MobileSyncFrameCodec.encodeFrame(JSONSerialization.data(withJSONObject: [
            "id": id,
            "ok": true,
            "result": [String: Any](),
        ]))
        await base.deliver(response)
    }

    func close() async {
        await base.close()
    }
}
