import Foundation
import Testing
@testable import CmuxNextApps

/// The client over a fake supervisor: intents, rejects, the disconnected
/// state, hide and unhide, mounts and reconnects.
@MainActor
struct AppsClientTests {
    @Test func installShowsAtOnceAndConvergesOnTheReply() async throws {
        let (client, transport) = await TestClient.make()
        transport.holdsReplies = true
        let id = "cmux/github-prs"
        // task-owner: test install held at the fake supervisor
        let install = Task { try await client.install(id) }
        #expect(await eventually { await MainActor.run { client.projection.isPending(id) } })
        #expect(client.app(id)?.installed == true)
        #expect(client.projection.mirror.first { $0.id == id }?.installed == false)
        transport.releaseReplies()
        try await install.value
        #expect(!client.projection.isPending(id))
        #expect(client.app(id)?.installed == true)
        #expect(client.app(id)?.source == .user)
        #expect(await eventually { await MainActor.run { client.projection.revision == transport.revision } })
    }

    @Test func aRefusedChangeAnimatesBackAndSaysWhy() async throws {
        let (client, transport) = await TestClient.make()
        transport.holdsReplies = true
        transport.refusal = { _, _, _ in AppsTransportError(code: "apps.disabled", message: "turned off by policy") }
        let id = "cmux/agent-status"
        // task-owner: test sandbox switch held at the fake supervisor
        let change = Task { try await client.set(id, .sandbox(true), origin: .user) }
        #expect(await eventually { await MainActor.run { client.app(id)?.sandboxed == true } })
        transport.releaseReplies()
        await #expect(throws: AppsClientError.refused(AppsTransportError(code: "apps.disabled", message: "turned off by policy"))) {
            try await change.value
        }
        #expect(client.app(id)?.sandboxed == false)
        #expect(client.rejections[id] == "turned off by policy")
        #expect(client.projection.pending.isEmpty)
    }

    @Test func withoutTheCapabilityEveryChangeIsRefusedAndNothingQueues() async throws {
        let (client, transport) = await TestClient.make(available: false)
        #expect(client.unavailableReason == .needsNewerDaemon)
        #expect(AppsStrings.unavailable(.needsNewerDaemon) == "Needs a newer cmux-tui")
        await #expect(throws: AppsClientError.unavailable(.needsNewerDaemon)) { try await client.install("cmux/github-prs") }
        await #expect(throws: AppsClientError.unavailable(.needsNewerDaemon)) {
            try await client.set("cmux/agent-status", .hide(true), origin: .cli)
        }
        #expect(client.projection.pending.isEmpty)
        #expect(transport.seenKeys.isEmpty)
        #expect(client.apps.isEmpty)
        let mount = client.mount("cmux/agent-status", implementation: AppImplementation(interface: AppImplementation.section, id: "agents"),
                                 surface: "sidebarSection")
        #expect(mount.model.status == .disconnected("Needs a newer cmux-tui"))
        #expect(transport.mounted.isEmpty)
    }

    /// The supervisor decides which origins may change what (D55: hide
    /// needs user); the client sends the caller's origin and shows the
    /// refusal. It has no origin rule of its own.
    @Test func theSupervisorDecidesOriginsAndTheClientShowsItsRefusal() async throws {
        let (client, transport) = await TestClient.make()
        let id = "cmux/agent-status"
        await #expect(throws: AppsClientError.refused(AppsTransportError(code: "apps.origin_forbidden", message: "needs a user gesture"))) {
            try await client.set(id, .hide(true), origin: .mcp)
        }
        #expect(client.app(id)?.hidden == false)
        #expect(client.rejections[id] == "needs a user gesture")
        try await client.set(id, .hide(true), origin: .user)
        #expect(client.app(id)?.hidden == true && client.app(id)?.isVisible == false && client.app(id)?.isActive == true)
        #expect(transport.seenKeys.count == 1, "the supervisor committed only the user change")
    }

    /// `apps-run` carries the caller's origin (a CLI run is not a user gesture).
    @Test func aRunCarriesTheCallersOrigin() async throws {
        let (client, transport) = await TestClient.make()
        _ = try? await client.run(app: "cmux/coderouter", op: "coderouter.app.open", origin: .cli)
        _ = try? await client.run(app: "cmux/coderouter", op: "coderouter.app.open", origin: .user)
        #expect(transport.runs.map(\.origin) == [.cli, .user])
    }

    @Test func aMountRendersTheSceneStreamAndSendsUserEvents() async throws {
        let (client, transport) = await TestClient.make()
        let record = try #require(client.app("cmux/agent-status"))
        let section = try #require(record.manifest.implementations.first)
        let mount = client.mount(record.id, implementation: section, surface: "sidebarSection")
        #expect(await eventually { await MainActor.run { mount.model.status == .ready } })
        #expect(transport.mounted[mount.id]?.context["contribution"] == .string("cmux/agent-status#\(section.id)"))
        mount.dispatch(node: "r0", event: "tap", payload: [:])
        #expect(await eventually { await MainActor.run { transport.dispatched.contains { $0.node == "r0" && $0.event == "tap" } } })
        client.unmount(mount)
        #expect(await eventually { await MainActor.run { transport.mounted[mount.id] == nil } })
    }

    @Test func aPreviewMountsAnAppThatIsNotInstalled() async throws {
        let (client, transport) = await TestClient.make()
        let record = try #require(client.app("cmux/github-prs"))
        #expect(!record.installed)
        let mount = client.mount(record.id, implementation: try #require(record.manifest.sections.first), surface: "sidebarSection", preview: true)
        #expect(await eventually { await MainActor.run { mount.model.status == .ready } })
        #expect(transport.mounted[mount.id]?.context["preview"] == true)
    }

    @Test func aReconnectRemountsAndListsAgain() async throws {
        let (client, transport) = await TestClient.make()
        let record = try #require(client.app("cmux/agent-status"))
        let mount = client.mount(record.id, implementation: try #require(record.manifest.implementations.first), surface: "sidebarSection")
        #expect(await eventually { await MainActor.run { mount.model.status == .ready } })
        transport.setAvailable(false)
        #expect(mount.model.status == .disconnected("cmux-tui is not connected"))
        await #expect(throws: AppsClientError.unavailable(.notConnected)) { try await client.set(record.id, .hide(true), origin: .user) }
        var changed = record
        changed.hidden = true
        transport.commitElsewhere(changed)
        transport.setAvailable(true)
        #expect(await eventually { await MainActor.run { mount.model.status == .ready && client.app(record.id)?.hidden == true } })
    }

    @Test func anotherClientsChangeArrivesThroughAppsChanged() async throws {
        let (client, transport) = await TestClient.make()
        var record = try #require(client.app("cmux/agent-status"))
        record.enabled = false
        transport.commitElsewhere(record)
        #expect(await eventually { await MainActor.run { client.app(record.id)?.enabled == false } })
    }

    @Test func startingListsOnce() async {
        let (_, transport) = await TestClient.make()
        #expect(transport.listCalls == 1)
    }

    /// Nothing queues: an intent whose connection drops before the reply
    /// leaves the log (no rejection, no resend); the next connection's list
    /// shows what the supervisor committed.
    @Test func anIntentInFlightAcrossADisconnectIsDroppedNotQueued() async throws {
        let (client, transport) = await TestClient.make()
        transport.holdsReplies = true
        let id = "cmux/agent-status"
        // task-owner: test hide held at the fake supervisor while the connection drops
        let change = Task { try await client.set(id, .hide(true), origin: .user) }
        #expect(await eventually { await MainActor.run { client.projection.isPending(id) } })
        transport.setAvailable(false)
        transport.releaseReplies()
        await #expect(throws: AppsClientError.unavailable(.notConnected)) { try await change.value }
        #expect(!client.projection.isPending(id))
        #expect(client.app(id)?.hidden == false)
        #expect(client.rejections[id] == nil)
        transport.holdsReplies = false
        transport.setAvailable(true)
        #expect(await eventually { await MainActor.run { client.projection.revision == transport.revision } })
        #expect(client.app(id)?.hidden == false)
        #expect(transport.seenKeys.isEmpty, "nothing was resent")
    }

    @Test func aHostRestartResetsTheMountsTree() async throws {
        let (client, transport) = await TestClient.make()
        let record = try #require(client.app("cmux/agent-status"))
        let mount = client.mount(record.id, implementation: try #require(record.manifest.implementations.first), surface: "statusItem")
        #expect(await eventually { await MainActor.run { mount.model.status == .ready } })
        // A node the restarted host no longer has must not survive the reset.
        mount.model.apply([.create(id: "stale", type: "Text", props: ["text": "old"])])
        #expect(mount.model.scene["stale"] != nil)
        transport.restartHost(mountID: mount.id)
        #expect(mount.model.scene["stale"] == nil)
        #expect(mount.model.scene.root != nil)
        #expect(mount.model.status == .ready)
    }

    /// An administrator turns apps off: every mount ends on the supervisor and
    /// shows the reason; turning them back on mounts them again.
    @Test func turningAppsOffEndsEveryMountAndBackOnRemounts() async throws {
        let (client, transport) = await TestClient.make()
        let record = try #require(client.app("cmux/agent-status"))
        let mount = client.mount(record.id, implementation: try #require(record.manifest.implementations.first), surface: "sidebarSection")
        #expect(await eventually { await MainActor.run { mount.model.status == .ready } })
        client.suspendMounts()
        transport.setAvailable(false, reason: .turnedOff("Turned off by your organization"))
        #expect(await eventually { await MainActor.run { transport.mounted.isEmpty } })
        #expect(mount.model.status == .disconnected("Turned off by your organization"))
        transport.setAvailable(true)
        #expect(await eventually { await MainActor.run { transport.mounted[mount.id] != nil && mount.model.status == .ready } })
    }
}
