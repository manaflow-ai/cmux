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

    /// `link.open` (deep links) navigates this Mac's windows, so a remote
    /// session must never drive it: not as a method name, and not through
    /// `action.run`, the v2 method that runs catalog actions by id.
    @Test func linkOpenCanNeverBeRelayed() {
        let policy = RemoteRelayPolicy(allowed: ["link.open", "action.run", "link.open_url", "cmux.link.open"])
        #expect(policy.allowed.isEmpty, "a method that opens a link or runs an action can never be allowlisted")
        let tab = "cmux://tab/tab_0123456789abcdef0123456789abcdef"
        #expect(RemoteRelayPolicy.denyAll.decide(method: "link.open", params: ["url": .string(tab)], owned: owned)
            == .deny(.notAllowlisted("link.open")))
        #expect(policy.decide(method: "action.run", params: ["action": .string("link.open"), "args": .object(["url": .string(tab)])],
                              owned: owned) == .deny(.notAllowlisted("action.run")))
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

    /// A `remote_view` tab record from another machine's tree never opens
    /// here, in every build (plans/cmux-next/remote-desktop.md 11.0): the
    /// gate drops the address before any page is made.
    @Test func remoteBrowserRecordsNeverOpenARemoteViewTab() {
        for address in ["cmux://remote-view?host=localhost&target=display:1&mode=control",
                        "cmux://remote-view?host=mock", "CMUX://REMOTE-VIEW?host=127.0.0.1", " cmux://remote-view?host=local "] {
            #expect(RemoteRelayPolicy.remoteBrowserURL(address) == nil, "\(address)")
        }
    }
}
