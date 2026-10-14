import AppKit
@testable import CmuxNextApp
import CmuxNextControl
import CmuxNextRemote
import CmuxNextSettings
import Foundation
import Testing

/// `debug.cloud.move_state` and `debug.cloud.move_seed` (cx-h9os2), the restore journey's read
/// and seed of Move to Cloud's kept state, at the control socket: no relay may forward either
/// (skills/cmux-socket-policy/references/remote-relay-authorization.md), and what the seed
/// records reads back the same from a second app on the same defaults, as after a relaunch.
@MainActor @Suite(.serialized)
struct CloudMoveStateDebugTests {
    /// Both methods are denied for a relay: not on the default (empty) allowlist, and dropped
    /// from any allowlist that names them, like every `debug.*` method. The policy still allows
    /// a listed read on an owned target and denies an unowned target and command params.
    @Test func noRelayForwardsTheMoveToCloudDebugMethods() {
        for method in [DebugCloudMoveMethods.state, DebugCloudMoveMethods.seed, "debug.windows"] {
            #expect(RemoteRelayPolicy.denyAll.decide(method: method, params: [:], owned: .init()) == .deny(.notAllowlisted(method)))
            let listed = RemoteRelayPolicy(allowed: [method])
            #expect(listed.allowed.isEmpty, "\(method) stays on a relay allowlist")
            #expect(listed.decide(method: method, params: [:], owned: .init()) == .deny(.notAllowlisted(method)))
        }
        let reads = RemoteRelayPolicy(allowed: ["workspace.list"])
        let owned = RemoteRelayPolicy.Ownership(workspaces: ["ws-remote"])
        #expect(reads.decide(method: "workspace.list", params: ["workspace_id": .string("ws-remote")], owned: owned) == .allow)
        #expect(reads.decide(method: "workspace.list", params: ["workspace_id": .string("ws-local")], owned: owned)
            == .deny(.unownedTarget("workspace_id", "ws-local")))
        #expect(reads.decide(method: "workspace.list", params: ["command": .string("id")], owned: owned) == .deny(.commandParam("command")))
    }

    #if DEBUG
    /// The seed records two moved chats, three move retries, a Bring Back Local retry, an Always
    /// folder and a dismissed offer; the read names them by ids, kinds and digests (no folder path,
    /// name or move key as text); a second app on the same defaults reads the same; a dropped
    /// record reads as gone.
    @Test func theSeededStateReadsBackTheSameFromAnotherAppOnTheSameDefaults() async throws {
        let suite = "cmux.test.cloudMoveState.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = Self.app(defaults), second = Self.app(defaults)

        let seeded = try await first.call(DebugCloudMoveMethods.seed, ["run": "t1"])
        let state = try await first.call(DebugCloudMoveMethods.state)
        #expect(seeded == state)
        #expect(Self.count(state, "moved_chats") == 2)
        #expect(Self.count(state, "move_retries") == 3)
        #expect(Self.count(state, "bring_back_retries") == 1)
        #expect(Self.count(state, "grants") == 1)
        #expect(Self.count(state, "dismissed") == 1)
        let text = state.compactText
        for hidden in ["/tmp/", "/work/", "move-key", "t1 chat"] { #expect(!text.contains(hidden), "the read sends \(hidden)") }
        #expect(state.objectValue?["dismissed"]?.arrayValue?.first?.objectValue?["matches_retry"] == .bool(true))

        #expect(try await second.call(DebugCloudMoveMethods.state) == state)

        // Seeding again replaces the earlier rj- records instead of adding to them.
        _ = try await first.call(DebugCloudMoveMethods.seed, ["run": "t2"])
        #expect(Self.count(try await second.call(DebugCloudMoveMethods.state), "moved_chats") == 2)

        #expect(try await first.call(DebugCloudMoveMethods.seed, ["drop": "moved_chat"]) == .object(["dropped": .bool(true)]))
        #expect(Self.count(try await second.call(DebugCloudMoveMethods.state), "moved_chats") == 1)
    }

    struct App {
        let services: AppServices
        let router: ControlRouter

        func call(_ method: String, _ params: [String: JSONValue] = [:]) async throws -> JSONValue {
            try await router.handle(ControlRequest(id: "1", method: method, params: params)).get()
        }
    }

    static func app(_ defaults: UserDefaults) -> App {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        services.cloud.move.ledger = defaults
        let router = ControlRouter(identity: ControlIdentity(version: "1.0", build: "1", bundleID: "com.cmuxterm.app.debug.test", tag: "test",
                                                             processID: getpid()),
                                   executor: RegistryControlBridge(registry: services.registry), settings: nil)
        router.register(DebugCloudMove.methods(services))
        return App(services: services, router: router)
    }

    static func count(_ state: JSONValue, _ key: String) -> Int? {
        guard case .object(let fields) = state, case .array(let rows)? = fields[key] else { return nil }
        return rows.count
    }
    #endif
}
