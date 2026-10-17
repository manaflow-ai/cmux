import Foundation
import Testing
@testable import CmuxSurfaceCatalogModel

@Suite("Internal receiver workspaces")
struct SurfaceInternalReceiverWorkspaceTests {
    private let vm = SurfaceMachineID.cloud("vm-receiver")
    private let receiverName = "cmux env 2EDB0839-7A4C-4E0B-9C61-8D0F1E2A3B4C"

    @Test("only a reserved title followed by a UUID is internal")
    func predicate() {
        #expect(SurfaceRemoteWorkspace.isInternalReceiverWorkspaceName(receiverName))
        #expect(SurfaceRemoteWorkspace.isInternalReceiverWorkspaceName(
            SurfaceRemoteWorkspace.internalReceiverWorkspaceName(title: SurfaceRemoteWorkspace.fileReceiverTitle)
        ))
        #expect(SurfaceRemoteWorkspace.isInternalReceiverWorkspaceName(
            SurfaceRemoteWorkspace.internalReceiverWorkspaceName(title: SurfaceRemoteWorkspace.environmentReceiverTitle)
        ))
        #expect(!SurfaceRemoteWorkspace.isInternalReceiverWorkspaceName("cmux env"))
        #expect(!SurfaceRemoteWorkspace.isInternalReceiverWorkspaceName("cmux env staging"))
        #expect(!SurfaceRemoteWorkspace.isInternalReceiverWorkspaceName("workspace-1"))
        #expect(!SurfaceRemoteWorkspace.isInternalReceiverWorkspaceName(" \(receiverName)"))
    }

    @Test("a link sweep closes leaked receivers only, and none while a delivery is in flight")
    func leakedReceiverSweep() {
        let workspaces = [
            SurfaceRemoteWorkspace(id: "ws-real", name: "workspace-1", index: 0, focused: false),
            SurfaceRemoteWorkspace(id: "ws-named", name: "cmux env staging", index: 1, focused: false),
            SurfaceRemoteWorkspace(id: "ws-recv-b", name: receiverName, index: 2, focused: false),
            SurfaceRemoteWorkspace(
                id: "ws-recv-a",
                name: SurfaceRemoteWorkspace.internalReceiverWorkspaceName(title: SurfaceRemoteWorkspace.fileReceiverTitle),
                index: 3,
                focused: true
            ),
        ]
        #expect(SurfaceRemoteWorkspace.leakedInternalReceiverIDs(in: workspaces, deliveriesInFlight: 0) == ["ws-recv-a", "ws-recv-b"])
        #expect(SurfaceRemoteWorkspace.leakedInternalReceiverIDs(in: workspaces, deliveriesInFlight: 1).isEmpty)
        #expect(SurfaceRemoteWorkspace.leakedInternalReceiverIDs(in: Array(workspaces.prefix(2)), deliveriesInFlight: 0).isEmpty)
    }

    @Test("a client-scoped sweep closes only receivers this Mac created")
    func clientScopedSweep() {
        let ours = SurfaceRemoteWorkspace.internalReceiverWorkspaceName(
            title: SurfaceRemoteWorkspace.environmentReceiverTitle, clientID: "mac-ours"
        )
        let theirs = SurfaceRemoteWorkspace.internalReceiverWorkspaceName(
            title: SurfaceRemoteWorkspace.fileReceiverTitle, clientID: "mac-theirs"
        )
        let workspaces = [
            SurfaceRemoteWorkspace(id: "ws-ours", name: ours, index: 0, focused: false),
            SurfaceRemoteWorkspace(id: "ws-theirs", name: theirs, index: 1, focused: false),
            SurfaceRemoteWorkspace(id: "ws-legacy", name: receiverName, index: 2, focused: false),
        ]
        #expect(workspaces.allSatisfy { $0.isInternalReceiver })
        #expect(workspaces.map { $0.internalReceiverClientID } == ["mac-ours", "mac-theirs", nil])
        #expect(SurfaceRemoteWorkspace.leakedInternalReceiverIDs(
            in: workspaces, deliveriesInFlight: 0, clientID: "mac-ours"
        ) == ["ws-ours"])
        #expect(SurfaceRemoteWorkspace.leakedInternalReceiverIDs(
            in: workspaces, deliveriesInFlight: 0
        ) == ["ws-legacy", "ws-ours", "ws-theirs"])
        #expect(!SurfaceRemoteWorkspace.isInternalReceiverWorkspaceName("cmux env a b \(UUID().uuidString)"))
    }

    @Test("the receiver workspace, its terminal and projections into it are hidden; the real workspace stays")
    func snapshotHidesReceiver() {
        let real = SurfaceRemoteWorkspace(id: "ws-real", name: "workspace-1", index: 0, focused: false)
        // The daemon reports the newest workspace as focused: the receiver.
        let receiver = SurfaceRemoteWorkspace(id: "ws-recv", name: receiverName, index: 1, focused: true)
        let starter = SurfaceResource(
            id: SurfaceResourceID(machine: vm, kind: .terminal, key: "term-real"),
            title: "zsh",
            lifecycle: .running,
            remoteWorkspace: real,
            remoteViews: [SurfaceRemoteView(tabID: "tab-real", workspace: real)]
        )
        let receiverTerminal = SurfaceResource(
            id: SurfaceResourceID(machine: vm, kind: .terminal, key: "term-recv"),
            title: "cmux env",
            lifecycle: .running,
            remoteWorkspace: receiver,
            remoteViews: [SurfaceRemoteView(tabID: "tab-recv", workspace: receiver)]
        )
        // A provisional row recorded before the graph names the workspace (name == id).
        let provisional = SurfaceResource(
            id: SurfaceResourceID(machine: vm, kind: .terminal, key: "term-recv-2"),
            title: "cmux env",
            lifecycle: .launching,
            remoteWorkspace: SurfaceRemoteWorkspace(id: "ws-recv", name: "ws-recv", index: 1, focused: false)
        )
        let shared = SurfaceResource(
            id: SurfaceResourceID(machine: vm, kind: .browser, key: "browser-1"),
            title: "docs",
            lifecycle: .running,
            remoteWorkspace: receiver,
            remoteViews: [
                SurfaceRemoteView(tabID: "tab-b1", workspace: receiver),
                SurfaceRemoteView(tabID: "tab-b2", workspace: real),
            ]
        )
        let local = UUID()
        let snapshot = SurfaceCatalogSnapshot(
            pendingWorkspaceCreations: [vm: ["ws-recv": UUID(), "ws-real": local]],
            machines: [SurfaceMachineInfo(
                id: vm, name: "brave-otter", status: "running", hasDesktop: false, linkState: .connected,
                remoteWorkspaces: [real, receiver]
            )],
            resources: [starter, receiverTerminal, provisional, shared],
            projections: [
                SurfaceProjection(resource: starter.id, workspaceID: local, panelID: UUID(), remoteWorkspaceID: "ws-real"),
                SurfaceProjection(resource: receiverTerminal.id, workspaceID: UUID(), panelID: UUID(), remoteWorkspaceID: "ws-recv"),
            ]
        )

        let visible = snapshot.hidingInternalReceiverWorkspaces()

        #expect(visible.machines.first?.remoteWorkspaces == [real])
        #expect(visible.machines.first?.remoteWorkspaces?.filter(\.focused).isEmpty == true)
        #expect(visible.resources.map(\.id.key) == ["term-real", "browser-1"])
        let browser = visible.resources.first { $0.id.key == "browser-1" }
        #expect(browser?.remoteViews?.map(\.tabID) == ["tab-b2"])
        #expect(browser?.remoteWorkspace == real)
        #expect(visible.projections.map(\.resource) == [starter.id])
        #expect(visible.pendingWorkspaceCreations == [vm: ["ws-real": local]])
    }

    @Test("a snapshot without receivers is returned unchanged")
    func noReceiverIsIdentity() {
        let real = SurfaceRemoteWorkspace(id: "ws-real", name: "cmux env staging", index: 0, focused: true)
        let snapshot = SurfaceCatalogSnapshot(
            machines: [SurfaceMachineInfo(
                id: vm, name: "brave-otter", status: "running", hasDesktop: false, linkState: .connected,
                remoteWorkspaces: [real]
            )],
            resources: [],
            projections: []
        )
        #expect(snapshot.hidingInternalReceiverWorkspaces() == snapshot)
    }
}
