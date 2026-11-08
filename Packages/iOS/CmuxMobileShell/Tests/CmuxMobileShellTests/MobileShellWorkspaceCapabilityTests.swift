import CMUXMobileCore
import CmuxMobileRPC
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Suite struct MobileShellWorkspaceCapabilityTests {
    @Test func workspaceChangesCapabilityFollowsHostStatusSet() {
        let store = MobileShellComposite.preview()
        #expect(!store.workspaceChangesCapable)

        store.supportedHostCapabilities = ["workspace.changes.v1"]
        #expect(store.workspaceChangesCapable)

        store.supportedHostCapabilities = ["workspace.actions.v1"]
        #expect(!store.workspaceChangesCapable)
    }

    @Test func artifactFolderCapabilitiesFailClosedForOlderHosts() {
        let store = MobileShellComposite.preview()
        store.supportedHostCapabilities = [
            "chat.artifact.v1",
            "terminal.artifact.v1",
        ]
        #expect(!store.supportsChatArtifactFolders)
        #expect(!store.supportsTerminalArtifactList)
        #expect(!store.supportsPanelArtifacts)
        #expect(!store.supportsIrohArtifactLane)

        store.supportedHostCapabilities.formUnion([
            "chat.artifact.folders.v1",
            "terminal.artifact.list.v1",
            "iroh.artifact_lane.v1",
            "panel.artifact.v1",
        ])
        #expect(store.supportsChatArtifactFolders)
        #expect(store.supportsTerminalArtifactList)
        #expect(store.supportsIrohArtifactLane)
        #expect(store.supportsPanelArtifacts)
    }

    @Test func workspaceMutationCapabilitiesAreVersionAndTicketGated() async throws {
        let oldMac = try await connectedStore(capabilities: [
            "events.v1",
            "terminal.render_grid.v1",
            "terminal.replay.v1",
            "workspace.actions.v1",
        ])
        #expect(oldMac.store.supportsWorkspaceActions)
        #expect(!oldMac.store.supportsWorkspaceMetadata)
        #expect(!oldMac.store.supportsWorkspaceReadStateActions && !oldMac.store.supportsWorkspaceCloseActions)
        #expect(!oldMac.store.supportsWorkspaceMoveActions && !oldMac.store.supportsWorkspaceGroupActions)
        #expect(!oldMac.store.supportsWorkspaceCreateInGroup)
        #expect(!oldMac.store.supportsWorkspaceGroupCreate)

        let metadataOnly = try await connectedStore(capabilities: [
            "events.v1",
            "terminal.render_grid.v1",
            "terminal.replay.v1",
            "workspace.metadata.v1",
        ])
        #expect(metadataOnly.store.supportsWorkspaceMetadata)
        #expect(metadataOnly.store.workspaces.first?.actionCapabilities.supportsWorkspaceMetadata == false)

        let currentCapabilities = [
            "events.v1",
            "terminal.render_grid.v1",
            "terminal.replay.v1",
            "workspace.actions.v1",
            "workspace.metadata.v1",
            "workspace.read_state.v1",
            "workspace.close.v1",
            "workspace.move.v1",
            "workspace.group_actions.v1",
            "workspace.create_in_group.v1",
            "workspace.group_create.v1",
        ]
        let scoped = try await connectedStore(capabilities: currentCapabilities)
        #expect(scoped.store.supportsWorkspaceMetadata)
        #expect(scoped.store.workspaces.first?.actionCapabilities.supportsWorkspaceMetadata == true)
        #expect(scoped.store.supportsWorkspaceReadStateActions && scoped.store.supportsWorkspaceCloseActions)
        #expect(!scoped.store.supportsWorkspaceMoveActions && !scoped.store.supportsWorkspaceGroupActions)
        #expect(!scoped.store.supportsWorkspaceCreateInGroup)
        #expect(!scoped.store.supportsWorkspaceGroupCreate)

        let macWide = try await connectedStore(
            capabilities: currentCapabilities,
            ticketWorkspaceID: "",
            ticketTerminalID: nil
        )
        #expect(macWide.store.supportsWorkspaceMoveActions && macWide.store.supportsWorkspaceGroupActions)
        #expect(macWide.store.supportsWorkspaceCreateInGroup)
        #expect(macWide.store.supportsWorkspaceGroupCreate)
    }

    @Test func staleMacScopedMutationCapabilitiesFailClosedAfterTicketExpires() async throws {
        let connected = try await connectedStore(
            capabilities: [
                "events.v1",
                "terminal.render_grid.v1",
                "terminal.replay.v1",
                "workspace.move.v1",
                "workspace.group_actions.v1",
                "workspace.create_in_group.v1",
                "workspace.group_create.v1",
            ],
            ticketWorkspaceID: "",
            ticketTerminalID: nil,
            ticketLifetime: 1
        )
        let store = connected.store
        let router = connected.router
        let clock = connected.clock
        let workspaceID = try #require(store.workspaces.first?.id)
        #expect(store.workspaces.first?.actionCapabilities.supportsMoveActions == true)
        store.workspaceGroups = [
            MobileWorkspaceGroupPreview(id: "group-a", name: "Group A", anchorWorkspaceID: workspaceID),
        ]

        clock.advance(by: 2)

        guard case .failure(.authorizationFailed) = await store.moveWorkspace(
            id: workspaceID,
            toGroup: nil,
            before: nil
        ) else {
            return #expect(Bool(false), "expired ticket should fail move before sending")
        }
        guard case .failure(.authorizationFailed) = await store.setWorkspaceGroupPinned(id: "group-a", true) else {
            return #expect(Bool(false), "expired ticket should fail group action before sending")
        }
        guard case .failure(.authorizationFailed) = await store.createWorkspaceRequest(inGroup: "group-a") else {
            return #expect(Bool(false), "expired ticket should fail create-in-group before sending")
        }
        guard case .failure(.authorizationFailed) = await store.createWorkspaceGroup() else {
            return #expect(Bool(false), "expired ticket should fail group create before sending")
        }
        #expect(await router.count(of: "workspace.move") == 0)
        #expect(await router.count(of: "workspace.group.action") == 0)
        #expect(await router.count(of: "workspace.create") == 0)
        #expect(await router.count(of: "workspace.group.create") == 0)
    }

    @Test func expiredMacWideTicketKeepsAdvertisedCreateActionsDiscoverable() async throws {
        let connected = try await connectedStore(
            capabilities: [
                "events.v1",
                "terminal.render_grid.v1",
                "terminal.replay.v1",
                "workspace.create_in_group.v1",
                "workspace.group_create.v1",
            ],
            ticketWorkspaceID: "",
            ticketTerminalID: nil,
            ticketLifetime: 1
        )

        connected.clock.advance(by: 2)

        #expect(connected.store.supportsWorkspaceCreateInGroup)
        #expect(connected.store.supportsWorkspaceGroupCreate)
    }

    @Test func accountAuthorizedGroupRenameSurvivesExpiredMacWideTicket() async throws {
        let connected = try await connectedStore(
            capabilities: [
                "events.v1",
                "terminal.render_grid.v1",
                "terminal.replay.v1",
                "workspace.group_actions.v1",
                "workspace.mutations.account_auth.v1",
            ],
            ticketWorkspaceID: "",
            ticketTerminalID: nil,
            ticketLifetime: 1
        )
        let store = connected.store
        let workspaceID = try #require(store.workspaces.first?.id)
        let scopedGroupID = MobileWorkspaceGroupPreview.ID(
            rawValue: "test-mac\u{1F}group-a"
        )
        store.workspaceGroups = [
            MobileWorkspaceGroupPreview(
                id: scopedGroupID,
                remoteGroupID: "group-a",
                macDeviceID: "test-mac",
                name: "Before",
                anchorWorkspaceID: workspaceID
            ),
        ]

        connected.clock.advance(by: 2)

        guard case .success = await store.renameWorkspaceGroup(id: scopedGroupID, title: "  yu  ") else {
            return #expect(Bool(false), "same-account group rename should outlive the route ticket")
        }
        let requests = await connected.router.groupActions()
        #expect(requests.count == 1)
        #expect(requests.first?.groupID == "group-a")
        #expect(requests.first?.action == "rename")
        #expect(requests.first?.title == "yu")
        let authorization = await connected.router.authorization(for: "workspace.group.action")
        #expect(authorization.count == 1)
        #expect(authorization.first?.attachToken == nil)
        #expect(authorization.first?.stackAccessToken == "test-stack-token")
    }

    @Test func accountAuthorizedGroupRenameIgnoresCurrentWorkspaceScopedRouteTicket() async throws {
        let connected = try await connectedStore(capabilities: [
            "events.v1",
            "terminal.render_grid.v1",
            "terminal.replay.v1",
            "workspace.group_actions.v1",
            "workspace.mutations.account_auth.v1",
        ])
        let store = connected.store
        let workspaceID = try #require(store.workspaces.first?.id)
        store.workspaceGroups = [
            MobileWorkspaceGroupPreview(id: "group-a", name: "Before", anchorWorkspaceID: workspaceID),
        ]

        #expect(store.supportsWorkspaceGroupActions)
        #expect(store.workspaces.first?.actionCapabilities.supportsGroupActions == true)
        guard case .success = await store.renameWorkspaceGroup(id: "group-a", title: "yu") else {
            return #expect(Bool(false), "same-account group rename should not be narrowed by a saved route ticket")
        }
        let authorization = await connected.router.authorization(for: "workspace.group.action")
        #expect(authorization.count == 1)
        #expect(authorization.first?.attachToken == nil)
        #expect(authorization.first?.stackAccessToken == "test-stack-token")
    }

    @Test func taskComposerEntrypointStaysAvailableWithNoConnectedMac() {
        let store = MobileShellComposite.preview()
        // With no Mac connected there is no capability snapshot to consult, so
        // the New Task entrypoint must stay visible; the composer itself warns
        // that no Mac is connected. Hiding here made the button vanish whenever
        // the phone was offline or between reconnects.
        #expect(store.supportsTaskComposer)
    }

    @Test func taskComposerEntrypointFollowsConnectedMacCapability() async throws {
        let capable = try await connectedStore(capabilities: [
            "events.v1",
            "terminal.render_grid.v1",
            "terminal.replay.v1",
            "workspace.task_create.v1",
        ])
        #expect(capable.store.supportsTaskComposer)

        // A connected Mac that does not advertise task creation (remote flag
        // off or an older build) is authoritative: the entrypoint hides.
        let incapable = try await connectedStore(capabilities: [
            "events.v1",
            "terminal.render_grid.v1",
            "terminal.replay.v1",
        ])
        #expect(!incapable.store.supportsTaskComposer)
    }

    @Test func taskComposerEntrypointFollowsSecondaryMacCapability() throws {
        let clock = TestClock()
        let runtime = LivenessTestRuntime(
            transportFactory: LivenessTransportFactory(
                router: LivenessHostRouter(),
                box: TransportBox()
            ),
            now: { clock.now }
        )
        let store = MobileShellComposite.preview(runtime: runtime)
        let ticket = try ticket(
            clock: clock,
            workspaceID: "live-workspace",
            terminalID: "live-terminal"
        )
        let route = try #require(ticket.routes.first)
        let client = MobileCoreRPCClient(
            runtime: runtime,
            route: route,
            ticket: ticket,
            allowsStackAuthFallback: true
        )
        let key = MacPairingKey(macDeviceID: "test-mac", instanceTag: nil)

        // A connected control secondary without task creation is the only
        // live Mac, and its snapshot is authoritative: the entrypoint hides.
        let incapable = SecondaryMacSubscription(
            macDeviceID: "test-mac",
            client: client,
            route: route,
            ticket: ticket,
            supportedHostCapabilities: ["terminal.render_grid.v1"],
            actionCapabilities: .none
        )
        store.secondaryMacSubscriptions[key] = incapable
        #expect(store.hasAnyConnectedMac)
        #expect(!store.supportsTaskComposer)
        store.secondaryMacSubscriptions[key] = nil
        incapable.cancel()

        // A capable secondary shows the entrypoint even though the
        // foreground connection is down.
        let capable = SecondaryMacSubscription(
            macDeviceID: "test-mac",
            client: client,
            route: route,
            ticket: ticket,
            supportedHostCapabilities: ["workspace.task_create.v1"],
            actionCapabilities: .none
        )
        store.secondaryMacSubscriptions[key] = capable
        #expect(store.supportsTaskComposer)
        store.secondaryMacSubscriptions[key] = nil
        capable.cancel()
    }

    @Test func hasAnyConnectedMacTracksForegroundSession() async throws {
        let offline = MobileShellComposite.preview()
        #expect(!offline.hasAnyConnectedMac)

        let connected = try await connectedStore(capabilities: [
            "events.v1",
            "terminal.render_grid.v1",
            "terminal.replay.v1",
        ])
        #expect(connected.store.hasAnyConnectedMac)
    }

    @Test func macScopedMutationsSurviveTicketExpiryOnAccountAuthHosts() async throws {
        let connected = try await connectedStore(
            capabilities: [
                "events.v1",
                "terminal.render_grid.v1",
                "terminal.replay.v1",
                "workspace.move.v1",
                "workspace.group_actions.v1",
                "workspace.create_in_group.v1",
                "workspace.group_create.v1",
                "workspace.mutations.account_auth.v1",
            ],
            ticketWorkspaceID: "",
            ticketTerminalID: nil,
            ticketLifetime: 1
        )
        let store = connected.store
        let router = connected.router
        let clock = connected.clock
        let workspaceID = try #require(store.workspaces.first?.id)
        #expect(store.workspaces.first?.actionCapabilities.supportsMoveActions == true)

        clock.advance(by: 2)

        // The pairing ticket has expired, but the host authorizes Mac-scoped
        // mutations by the signed-in account: the affordances must stay on and
        // the mutation RPCs must actually be sent.
        #expect(store.supportsWorkspaceMoveActions)
        #expect(store.supportsWorkspaceGroupActions)
        #expect(store.supportsWorkspaceCreateInGroup)
        #expect(store.supportsWorkspaceGroupCreate)
        _ = await store.moveWorkspace(id: workspaceID, toGroup: nil, before: nil)
        #expect(await router.count(of: "workspace.move") == 1)
    }

    private func connectedStore(
        capabilities: [String],
        ticketWorkspaceID: String = "live-workspace",
        ticketTerminalID: String? = "live-terminal",
        ticketLifetime: TimeInterval = 3_600
    ) async throws -> (store: MobileShellComposite, router: LivenessHostRouter, clock: TestClock) {
        let clock = TestClock()
        let router = LivenessHostRouter()
        let box = TransportBox()
        await router.setCapabilities(capabilities)
        let runtime = LivenessTestRuntime(
            transportFactory: LivenessTransportFactory(router: router, box: box),
            now: { clock.now }
        )
        let store = MobileShellComposite.preview(runtime: runtime)
        store.signIn()
        let connected = await store.connectPairingURL(try attachURL(for: try ticket(
            clock: clock,
            workspaceID: ticketWorkspaceID,
            terminalID: ticketTerminalID,
            lifetime: ticketLifetime
        )))
        #expect(connected, "scripted connect must succeed")
        let expectedCapabilities = Set(capabilities)
        let resolved = try await pollUntil {
            store.supportedHostCapabilities == expectedCapabilities
        }
        #expect(resolved, "scripted connect must resolve host capabilities")
        return (store, router, clock)
    }

    private func ticket(
        clock: TestClock,
        workspaceID: String,
        terminalID: String?,
        lifetime: TimeInterval = 3_600
    ) throws -> CmxAttachTicket {
        let route = try CmxAttachRoute(
            id: "debug_loopback",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 56584)
        )
        return try CmxAttachTicket(
            workspaceID: workspaceID,
            terminalID: terminalID,
            macDeviceID: "test-mac",
            macDisplayName: "Test Mac",
            macPairingCompatibilityVersion: CmxMobileDefaults.pairingCompatibilityVersion,
            routes: [route],
            expiresAt: clock.now.addingTimeInterval(lifetime),
            authToken: "ticket-secret"
        )
    }
}
