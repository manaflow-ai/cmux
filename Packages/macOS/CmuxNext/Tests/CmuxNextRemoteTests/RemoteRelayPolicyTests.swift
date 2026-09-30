@testable import CmuxNextRemote
import Foundation
import Testing

/// skills/cmux-socket-policy/references/remote-relay-authorization.md: a
/// request that originates on a remote machine is denied unless an explicit
/// allowlist entry, scoped to objects that machine owns, allows it.
@Suite struct RemoteRelayPolicyTests {
    let owned = RemoteRelayPolicy.Ownership(workspaces: ["ws_a"], surfaces: ["sf_1"], tabs: ["tab_1"])

    @Test func everythingIsDeniedByDefault() {
        let policy = RemoteRelayPolicy.denyAll
        for method in ["workspace.list", "system.ping", "surface.send_text", "notification.create", "workspace.create", "browser.open"] {
            #expect(policy.decide(method: method, params: [:], owned: owned) == .deny(.notAllowlisted(method)), "\(method)")
        }
    }

    @Test func anAllowlistedMethodWorksOnlyOnOwnedObjects() {
        let policy = RemoteRelayPolicy(allowed: ["notification.create"])
        #expect(policy.decide(method: "notification.create", params: ["workspace_id": .string("ws_a"), "title": .string("done")], owned: owned) == .allow)
        #expect(policy.decide(method: "notification.create", params: ["workspace_id": .string("ws_local")], owned: owned)
            == .deny(.unownedTarget("workspace_id", "ws_local")))
        #expect(policy.decide(method: "notification.create", params: ["surface_ids": .array([.string("sf_1"), .string("sf_mac")])], owned: owned)
            == .deny(.unownedTarget("surface_ids", "sf_mac")))
        #expect(policy.decide(method: "notification.create", params: ["target_workspace_id": .string("ws_b")], owned: owned)
            == .deny(.unownedTarget("target_workspace_id", "ws_b")))
        // Ref forms (workspace:3) never resolve for a remote caller.
        #expect(policy.decide(method: "notification.create", params: ["workspace_id": .string("workspace:1")], owned: owned)
            == .deny(.unownedTarget("workspace_id", "workspace:1")))
    }

    @Test func commandBearingParamsAreDeniedEvenOnAllowlistedMethods() {
        let policy = RemoteRelayPolicy(allowed: ["notification.create"])
        for key in ["initial_command", "command", "tmux_start_command", "pane_start_command"] {
            #expect(policy.decide(method: "notification.create", params: [key: .string("rm -rf ~"), "workspace_id": .string("ws_a")], owned: owned)
                == .deny(.commandParam(key)), "\(key)")
        }
    }

    @Test func spawningAndInputMethodsCanNeverBeAllowlisted() {
        let policy = RemoteRelayPolicy(allowed: ["surface.send_text", "workspace.create", "surface.respawn", "browser.eval", "app.open_url"])
        #expect(policy.allowed.isEmpty, "the policy drops methods that run commands or open content locally")
        #expect(policy.decide(method: "surface.send_text", params: ["surface_id": .string("sf_1")], owned: owned)
            == .deny(.notAllowlisted("surface.send_text")))
    }

    @Test func remoteBrowserRecordsOpenOnlyWebPages() {
        #expect(RemoteRelayPolicy.remoteBrowserURL("https://example.com/a")?.absoluteString == "https://example.com/a")
        #expect(RemoteRelayPolicy.remoteBrowserURL("http://build-box:3000/")?.absoluteString == "http://build-box:3000/")
        #expect(RemoteRelayPolicy.remoteBrowserURL("about:blank")?.absoluteString == "about:blank")
        for denied in ["file:///Users/me/.ssh/id_ed25519", "javascript:alert(1)", "data:text/html,<script>", "cmux://open?x",
                       "x-apple.systempreferences:", "ftp://host/", "chrome://settings", "vnc://host", "  "] {
            #expect(RemoteRelayPolicy.remoteBrowserURL(denied) == nil, "\(denied)")
        }
        #expect(RemoteRelayPolicy.remoteBrowserURL(nil) == nil)
    }
}
