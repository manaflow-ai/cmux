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
    func aLocalDestinationTitleCreatesALocalChat(targeted: Bool) async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            services.agentTabs.localHost = AgentSessionRef.host(installID: "local-destination-fixture")
            try #require(services.agentTabs.canHostChat, "this build has no agent page")
            let pane = try #require(services.windows.active?.focusedPane)
            let before = Set(PasswordManagerRouteTests.tabs(services).map(\.id))
            let source = AgentChatDestinationsTests.source
            let invocation = ActionInvocation(
                target: targeted ? ActionTargetRef(kind: .pane, id: pane.paneKey) : nil,
                arguments: ["host": .string(source.local.title), "cwd": .string("/tmp")], origin: .cli)
            let result = await AgentHandlers.createOnHost(source.local.title, invocation: invocation,
                destinations: source, context: AppActionContext(services: services))
            _ = try result.get()
            try await PasswordManagerRouteTests.until {
                PasswordManagerRouteTests.tabs(services).contains { !before.contains($0.id) }
            }
            let created = try #require(PasswordManagerRouteTests.tabs(services).first { !before.contains($0.id) })
            let view = try #require(services.agentTabs.view(for: created.id))
            let reply = await view.model.respond(to: AgentPaneRequest(body: ["method": "ready"]))
            let handshake = try #require(reply["value"] as? [String: Any], "\(reply)")
            #expect(handshake["cwd"] as? String == "/tmp")
            #expect(handshake["peer"] == nil, "a resolved local title is not an acpmux peer")
            #expect(!view.model.remoteChat)
        }
    }

    @Test(arguments: [false, true], [ActionOrigin.cli, .mcp])
    func peerCreationKeepsTheRequestedFolderAndPicks(targeted: Bool, origin: ActionOrigin) async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
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
            _ = try result.get()
            try await PasswordManagerRouteTests.until {
                PasswordManagerRouteTests.tabs(services).contains { !before.contains($0.id) }
            }
            let created = try #require(PasswordManagerRouteTests.tabs(services).first { !before.contains($0.id) })
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
        try await PasswordManagerRouteTests.withApp { services, _ in
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
        try await PasswordManagerRouteTests.withApp { services, _ in
            services.agentTabs.localHost = AgentSessionRef.host(installID: "palette-destination-fixture")
            try #require(services.agentTabs.canHostChat, "this build has no agent page")
            let before = Set(PasswordManagerRouteTests.tabs(services).map(\.id))
            // No test binding: this must be the handler installed by AppActions.bind.
            let run = RegistryControlBridge(registry: services.registry).performActionTracked(
                ControlActionRequest(actionID: "palette.newAgentChatOn",
                                     arguments: ["host": .string("local")], origin: ActionOrigin.cli.rawValue))
            #expect(run.outcome == .ran, "\(run.outcome)")
            for work in run.work { #expect(await work.value == nil) }
            try await PasswordManagerRouteTests.until {
                PasswordManagerRouteTests.tabs(services).contains { !before.contains($0.id) }
            }
            let created = try #require(PasswordManagerRouteTests.tabs(services).first { !before.contains($0.id) })
            #expect(created.agentSession != nil)
        }
    }
}
