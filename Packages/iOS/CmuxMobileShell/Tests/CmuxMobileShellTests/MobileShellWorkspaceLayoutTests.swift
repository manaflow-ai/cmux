import CMUXMobileCore
import CmuxMobileRPC
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Suite struct MobileShellWorkspaceLayoutTests {
    @Test func appliesCapableWorkspaceLayoutUpdatedEvent() throws {
        let store = MobileShellComposite.preview()
        let workspace = try #require(store.workspaces.first)
        store.supportedHostCapabilities = ["workspace.layout.v1"]
        store.replaceForegroundWorkspaceState([workspace])
        let rowID = try #require(store.workspaces.first?.id)
        let layout = Self.layout(workspaceID: workspace.rpcWorkspaceID.rawValue, paneID: "pane-1")
        let event = MobileEventEnvelope(
            topic: "workspace.layout.updated",
            payloadJSON: try JSONEncoder().encode(layout),
            streamID: "test-stream"
        )

        store.handleWorkspaceLayoutUpdatedEvent(event)

        #expect(store.supportsWorkspaceLayout(for: rowID))
        #expect(store.workspaceLayout(for: rowID) == layout)
        #expect(store.selectedWorkspaceLayout == layout)
    }

    @Test func capabilityGateAndStorageArePerMacWhenRemoteIDsCollide() throws {
        let store = MobileShellComposite.preview()
        let remoteID = MobileWorkspacePreview.ID(rawValue: "shared-workspace")
        let workspace = MobileWorkspacePreview(
            id: remoteID,
            name: "Workspace",
            terminals: []
        )
        store.setWorkspaceStatesForTesting([
            "mac-a": MacWorkspaceState(
                macDeviceID: "mac-a",
                workspaces: [workspace],
                status: .connected,
                supportsWorkspaceLayout: true
            ),
            "mac-b": MacWorkspaceState(
                macDeviceID: "mac-b",
                workspaces: [workspace],
                status: .connected,
                supportsWorkspaceLayout: false
            ),
        ], foregroundMacDeviceID: "mac-a")
        let rowA = try #require(store.workspaces.first(where: { $0.macDeviceID == "mac-a" })?.id)
        let rowB = try #require(store.workspaces.first(where: { $0.macDeviceID == "mac-b" })?.id)
        let layoutA = Self.layout(workspaceID: remoteID.rawValue, paneID: "pane-a")
        let layoutB = Self.layout(workspaceID: remoteID.rawValue, paneID: "pane-b")

        store.handleWorkspaceLayoutUpdatedEvent(
            try Self.event(layoutA),
            macDeviceID: "mac-a"
        )
        store.handleWorkspaceLayoutUpdatedEvent(
            try Self.event(layoutB),
            macDeviceID: "mac-b"
        )

        #expect(store.supportsWorkspaceLayout(for: rowA))
        #expect(!store.supportsWorkspaceLayout(for: rowB))
        #expect(store.workspaceLayout(for: rowA) == layoutA)
        #expect(store.workspaceLayout(for: rowB) == nil)

        store.setWorkspaceStatesForTesting([
            "mac-a": MacWorkspaceState(
                macDeviceID: "mac-a",
                workspaces: [workspace],
                status: .connected,
                supportsWorkspaceLayout: true
            ),
            "mac-b": MacWorkspaceState(
                macDeviceID: "mac-b",
                workspaces: [workspace],
                status: .connected,
                supportsWorkspaceLayout: true
            ),
        ], foregroundMacDeviceID: "mac-a")
        store.handleWorkspaceLayoutUpdatedEvent(
            try Self.event(layoutB),
            macDeviceID: "mac-b"
        )

        #expect(store.workspaceLayout(for: rowA) == layoutA)
        #expect(store.workspaceLayout(for: rowB) == layoutB)
    }

    @Test func malformedLayoutUpdatePreservesLastGoodSnapshot() throws {
        let store = MobileShellComposite.preview()
        let workspace = try #require(store.workspaces.first)
        store.supportedHostCapabilities = ["workspace.layout.v1"]
        store.replaceForegroundWorkspaceState([workspace])
        let rowID = try #require(store.workspaces.first?.id)
        let layout = Self.layout(
            workspaceID: workspace.rpcWorkspaceID.rawValue,
            paneID: "pane-1"
        )
        store.handleWorkspaceLayoutUpdatedEvent(try Self.event(layout))

        store.handleWorkspaceLayoutUpdatedEvent(MobileEventEnvelope(
            topic: "workspace.layout.updated",
            payloadJSON: Data("{not-json".utf8),
            streamID: nil
        ))

        #expect(store.workspaceLayout(for: rowID) == layout)
    }

    private static func layout(workspaceID: String, paneID: String) -> MobileWorkspaceLayout {
        MobileWorkspaceLayout(
            workspaceID: workspaceID,
            root: .pane(MobileWorkspacePane(
                id: paneID,
                frame: .unit,
                tabs: [MobileWorkspaceTab(
                    id: "terminal-1",
                    name: "Agent",
                    kind: .terminal,
                    isActive: true,
                    isReady: true,
                    agentStatus: .running
                )]
            )),
            activePaneID: paneID
        )
    }

    private static func event(_ layout: MobileWorkspaceLayout) throws -> MobileEventEnvelope {
        MobileEventEnvelope(
            topic: "workspace.layout.updated",
            payloadJSON: try JSONEncoder().encode(layout),
            streamID: "test-stream"
        )
    }
}
