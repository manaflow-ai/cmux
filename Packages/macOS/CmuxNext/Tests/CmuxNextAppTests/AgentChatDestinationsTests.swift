import CmuxNextActions
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextControl
import CmuxNextDaemon
@testable import CmuxNextPalette
import Foundation
import Testing

@MainActor @Suite
struct AgentChatDestinationsTests {
    static func focusedCloud(_ services: AppServices) -> CloudMachineSession {
        let session = MachineIconTests.cloudMachine(services, id: "vm-chat-focus")
        let first = PaneSnapshot(id: PaneID(rawValue: 11), focusedAt: 1,
            tabs: [TabSnapshot(surface: SurfaceID(rawValue: 11), cwd: "/unrelated")])
        let other = PaneSnapshot(id: PaneID(rawValue: 21), focusedAt: 2,
            tabs: [TabSnapshot(surface: SurfaceID(rawValue: 21), cwd: "/other")])
        let focused = PaneSnapshot(id: PaneID(rawValue: 22), focusedAt: 9,
            tabs: [TabSnapshot(surface: SurfaceID(rawValue: 22), cwd: "/focused-project")])
        session.daemon.store.apply(snapshot: DaemonTree(workspaces: [
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: WorkspaceKey(rawValue: "first-project"), name: "First",
                screens: [ScreenSnapshot(id: ScreenID(rawValue: 1), layout: .leaf(first.id), panes: [first])]),
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 2), key: WorkspaceKey(rawValue: "focused-project"), name: "Focused",
                screens: [ScreenSnapshot(id: ScreenID(rawValue: 2), layout: .leaf(other.id), panes: [other, focused])]),
        ]))
        return session
    }

    @Test func aCloudDestinationUsesItsFocusedWorkspaceAndPane() throws {
        let services = MachineIconTests.services()
        let session = Self.focusedCloud(services)
        let destination = try #require(AgentChatPlacement.destination(on: session.daemon, services: services))
        #expect(destination.daemon === session.daemon)
        #expect(destination.workspace.id == "focused-project")
        #expect(destination.pane.handle == PaneID(rawValue: 22))
        #expect(destination.cwd(nil) == "/focused-project")
        #expect(destination.cwd("/explicit") == "/explicit")
    }

    static var source: AgentChatDestinations {
        AgentChatDestinations(localTitle: "This Mac", peers: {
            [AgentChatPeer(name: "dev-box", isSSH: true, connected: true, state: "connected"),
             AgentChatPeer(name: "build-box", isSSH: true, connected: true, state: "reconnecting"),
             AgentChatPeer(name: "cloud-peer", isSSH: false, connected: true, state: "connected")]
        }, cloud: {
            .init(signedIn: true, loaded: true, machines: [
                .init(id: "duplicate", name: "CLOUD-PEER", stage: "ready"),
                .init(id: "vm-ready", name: "Cloud workspace", stage: "ready"),
                .init(id: "vm-paused", name: "Paused workspace", stage: "paused"),
            ])
        })
    }

    final class EmptyTargets: PaletteTargetSource {
        func targets(of kind: ActionTargetKind) -> [PaletteTargetOption] { [] }
    }

    @Test func peerAndAccountCloudRowsKeepTheirAuthoritativeState() async throws {
        let rows = await Self.source.load()
        #expect(rows.map(\.id) == ["local", "dev-box", "build-box", "cloud-peer", "cloud-machine:vm-ready", "cloud-machine:vm-paused"])
        #expect(rows.first { $0.id == "build-box" }?.isReady == false)
        #expect(rows.first { $0.id == "build-box" }?.state == "reconnecting")
        #expect(rows.first { $0.id == "cloud-machine:vm-paused" }?.isReady == false)
        #expect(AgentChatDestinations.resolve("vm-ready", in: rows)?.route == .cloud("vm-ready"))
        #expect(AgentChatDestinations.resolve("dev-box", in: rows)?.route == .peer("dev-box"))
        #expect(AgentChatDestinations.resolve("missing", in: rows) == nil)
    }

    @Test func paletteLoadsTheSameRowsAndForwardsTheChosenHost() async throws {
        let registry = ActionRegistry.standard()
        var chosen: String?
        registry.bind("palette.newAgentChatOn", run: { chosen = $0["host"]?.targetValue?.id })
        let descriptor = try #require(ActionCatalog.all.first { $0.id == "palette.newAgentChatOn" })
        let source = PaletteSourcesBridge.agentChatTargets(Self.source, next: EmptyTargets())
        let flow = PaletteArgumentFlow(registry: registry, descriptor: descriptor, targets: source)
        guard case .push(let page) = flow.effect(collected: ActionInvocation()) else { Issue.record("no chooser"); return }
        let provider = try #require(page.providers.first)
        #expect(provider.immediateItems?.first?.id == "option:local")
        #expect(provider.refreshesOnOpen)
        let items = await provider.items()
        let offline = try #require(items.first { $0.id == "option:build-box" })
        #expect(!offline.isEnabled)
        #expect(offline.subtitle == "reconnecting")
        let peer = try #require(items.first { $0.id == "option:dev-box" })
        guard case .perform(let pick) = peer.primary.effect else { Issue.record("no pick"); return }
        pick()
        #expect(chosen == "dev-box")
        #expect(items.first { $0.id == "option:cloud-machine:vm-ready" }?.isEnabled == true)
        // Other machine actions still read their existing target source.
        #expect(source.targets(of: .machine, for: "workspace.newOnMachine").isEmpty)
    }

    @Test func signingOutDropsTheAccountInventory() {
        let rows = AgentChatDestinations.rows(localTitle: "This Mac", peers: [], cloud: .init(signedIn: false, loaded: true,
            machines: [.init(id: "old-account", name: "Old account", stage: "ready")]))
        #expect(rows.map(\.id) == ["local"])
    }
}

/// These run the real tab creation path against the same-tree daemon. The inventory is public
/// fixture data; no remote account or peer process is needed to check routing and refusals.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct AgentChatDestinationActionTests {
    @Test(arguments: [false, true])
    func cloudPlacementUsesWindowFocusBeforeDaemonRecency(away: Bool) async throws {
        try await AgentChatActionFixture.withApp { services, _ in
            let window = try #require(services.windows.active)
            let localWorkspace = window.state.workspaceID
            let session = AgentChatDestinationsTests.focusedCloud(services)
            window.state.machineID = session.machineID
            window.state.workspaceID = "focused-project"
            // A workspace switch updates this selection before the mounted content/focus
            // topology catches up. Its remembered pane must beat the old workspace's focus.
            #expect(window.state.focus.state.topology.workspace != "focused-project")
            window.state.focus.send(.restoredPane("pane:21", workspace: "focused-project"))
            if away {
                window.state.machineID = MachineRegistry.localID
                window.state.workspaceID = localWorkspace
            }
            let destination = try #require(AgentChatPlacement.destination(on: session.daemon, services: services))
            #expect(destination.workspace.id == "focused-project")
            #expect(destination.pane.handle == PaneID(rawValue: 21))
            #expect(destination.cwd(nil) == "/other")
        }
    }

    @Test(arguments: ["local", "This Mac", "dev-box"])
    func aLocalOrPeerDestinationWorksWhileARemoteDaemonIsActive(host: String) async throws {
        try await AgentChatActionFixture.withApp { services, _ in
            services.agentTabs.localHost = AgentSessionRef.host(installID: "destination-from-remote")
            try #require(services.agentTabs.canHostChat)
            let remote = MachineIconTests.cloudMachine(services, id: "vm-current-chat")
            services.routedDaemon = remote.daemon
            defer { services.routedDaemon = nil }
            #expect(!services.activeDaemon.isLocal)
            let before = Set(PasswordManagerRouteTests.tabs(services).map(\.id))
            let cwd = host == "dev-box" ? "/tmp" : AgentChatActionFixture.localCwd
            let invocation = ActionInvocation(arguments: ["host": .string(host), "cwd": .string(cwd)], origin: .cli)
            let result = await AgentHandlers.createOnHost(host, invocation: invocation,
                destinations: AgentChatDestinationsTests.source, context: AppActionContext(services: services))
            let created = try await AgentChatActionFixture.created(in: services, after: before, fields: result.get())
            let view = try #require(services.agentTabs.view(for: created.id))
            let reply = await view.model.respond(to: AgentPaneRequest(body: ["method": "ready"]))
            let handshake = try #require(reply["value"] as? [String: Any], "\(reply)")
            #expect(handshake["cwd"] as? String == cwd)
            #expect(handshake["peer"] as? String == (host == "dev-box" ? host : nil))
            #expect(remote.daemon.store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).isEmpty)
        }
    }

    @Test(arguments: [false, true])
    func aLocalDestinationTitleCreatesALocalChat(targeted: Bool) async throws {
        try await AgentChatActionFixture.withApp { services, _ in
            services.agentTabs.localHost = AgentSessionRef.host(installID: "local-destination-fixture")
            try #require(services.agentTabs.canHostChat, "this build has no agent page")
            let pane = try #require(services.windows.active?.focusedPane)
            let before = Set(PasswordManagerRouteTests.tabs(services).map(\.id))
            let source = AgentChatDestinationsTests.source
            let invocation = ActionInvocation(
                target: targeted ? ActionTargetRef(kind: .pane, id: pane.paneKey) : nil,
                arguments: ["host": .string(source.local.title), "cwd": .string(AgentChatActionFixture.localCwd)], origin: .cli)
            let result = await AgentHandlers.createOnHost(source.local.title, invocation: invocation,
                destinations: source, context: AppActionContext(services: services))
            let created = try await AgentChatActionFixture.created(in: services, after: before, fields: result.get())
            let view = try #require(services.agentTabs.view(for: created.id))
            let reply = await view.model.respond(to: AgentPaneRequest(body: ["method": "ready"]))
            let handshake = try #require(reply["value"] as? [String: Any], "\(reply)")
            #expect(handshake["cwd"] as? String == AgentChatActionFixture.localCwd)
            #expect(handshake["peer"] == nil, "a resolved local title is not an acpmux peer")
            #expect(!view.model.remoteChat)
        }
    }

    @Test(arguments: [false, true], [ActionOrigin.cli, .mcp])
    func peerCreationKeepsTheRequestedFolderAndPicks(targeted: Bool, origin: ActionOrigin) async throws {
        try await AgentChatActionFixture.withApp { services, _ in
            services.agentTabs.localHost = AgentSessionRef.host(installID: "destination-action-fixture")
            try #require(services.agentTabs.canHostChat, "this build has no agent page")
            let pane = try #require(services.windows.active?.focusedPane)
            let before = Set(PasswordManagerRouteTests.tabs(services).map(\.id))
            let invocation = ActionInvocation(
                target: targeted ? ActionTargetRef(kind: .pane, id: pane.paneKey) : nil,
                arguments: ["host": .string("dev-box"), "cwd": .string("/tmp"),
                            "harness": .string("fake"), "model": .string("fixture-model")], origin: origin)
            let result = await AgentHandlers.createOnHost("dev-box", invocation: invocation,
                destinations: AgentChatDestinationsTests.source, context: AppActionContext(services: services))
            let created = try await AgentChatActionFixture.created(in: services, after: before, fields: result.get())
            #expect(pane.pane.tabs.contains { $0.id == created.id }, "the peer chat keeps the requested local pane")
            let view = try #require(services.agentTabs.view(for: created.id))
            let reply = await view.model.respond(to: AgentPaneRequest(body: ["method": "ready"]))
            let handshake = try #require(reply["value"] as? [String: Any], "\(reply)")
            #expect(handshake["cwd"] as? String == "/tmp", "the created chat's actual folder")
            #expect(view.model.handshakeCwd == "/tmp")
            #expect(handshake["peer"] as? String == "dev-box")
            #expect(handshake["harness"] as? String == "fake")
            #expect(handshake["model"] as? String == "fixture-model")
            #expect(view.model.remoteChat)
        }
    }

    @Test(arguments: ["missing", "build-box", "cloud-machine:vm-paused", "cloud-machine:vm-ready"])
    func unavailableDestinationsNeverCreateALocalFallback(host: String) async throws {
        try await AgentChatActionFixture.withApp { services, _ in
            services.agentTabs.localHost = AgentSessionRef.host(installID: "destination-refusal-fixture")
            let before = Set(PasswordManagerRouteTests.tabs(services).map(\.id))
            let invocation = ActionInvocation(arguments: ["host": .string(host), "cwd": .string("/tmp")], origin: .cli)
            let result = await AgentHandlers.createOnHost(host, invocation: invocation,
                destinations: AgentChatDestinationsTests.source, context: AppActionContext(services: services))
            guard case .failure(let failure) = result else { Issue.record("unavailable destination created a chat"); return }
            if host == "missing" { #expect(failure.refusal == .notFound) }
            else { #expect(!failure.message.isEmpty) }
            // A stale ready Cloud row must revalidate the actual signed-in account and live
            // machine before creating anything. The fixture app has neither.
            #expect(Set(PasswordManagerRouteTests.tabs(services).map(\.id)) == before)
        }
    }

    @Test func theBoundPaletteChooserCreatesAChatThroughTheCanonicalAction() async throws {
        try await AgentChatActionFixture.withApp { services, _ in
            services.agentTabs.localHost = AgentSessionRef.host(installID: "palette-destination-fixture")
            try #require(services.agentTabs.canHostChat, "this build has no agent page")
            let before = Set(PasswordManagerRouteTests.tabs(services).map(\.id))
            // No test binding: this must be the handler installed by AppActions.bind.
            let run = RegistryControlBridge(registry: services.registry).performActionTracked(
                ControlActionRequest(actionID: "palette.newAgentChatOn",
                                     arguments: ["host": .string("local")], origin: ActionOrigin.cli.rawValue))
            let fields = try await AgentChatActionFixture.finish(run)
            let created = try await AgentChatActionFixture.created(in: services, after: before, fields: fields)
            #expect(created.agentSession != nil)
        }
    }
}
