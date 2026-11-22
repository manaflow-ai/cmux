import Foundation
import Synchronization
import Testing
@testable import CmuxNextDaemon

/// A Cloud VM keeps the cmux-tui its image baked until the machine upgrades.
/// This one is commit 7d177547949b (protocol 12): it advertises the 28
/// capabilities below and answers "unknown variant" to every command outside
/// its command list. The app connects to it as a limited machine and must
/// never send it one of those commands: each one fails with an error the
/// user cannot act on, on every call.
@Suite(.timeLimit(.minutes(1))) struct CloudVMDaemonGateTests {
    /// `advertised_capabilities` of cmux-tui 7d177547949b (server.rs).
    static let capabilities: [String] = [
        "attach-initial-size", "attach-identity-v1", "workspace-registry-v1", "daemon-handoff-force-v1",
        "browser-pointer-frame-guard-v1", "viewport-splits-v1", "viewport-column-resize-v1", "layout-undo-v1",
        "tab-workspace-move-v1", "clear-history-v1", "surface-subscribe-filter", "session-journal-v1",
        "frontend-journal-v1", "view-attachment-lease-v1", "view-attachment-detach-v1", "shared-sizing-v1",
        "terminal-color-overrides-v1", "terminal-pending-sequence-v1", "creation-receipts-v1",
        "creation-attempt-keys-v1", "creation-selector-fallbacks-v1",
        "provider-managed-workspace-authority-v2", "browser-provider-v1", "client-focus-v1",
        "machine-usage-v1", "machine-listening-tcp-v1", "server-stats-v1", "terminal-idle-close-v1"
    ]

    /// The `commands` groups of cmux-tui 7d177547949b (spec/inventory.json).
    static let commands: Set<String> = [
        "apply-layout", "attach-surface", "browser-activate", "browser-back", "browser-forward",
        "browser-frame-presented", "browser-insert-text", "browser-key", "browser-key-press", "browser-mouse",
        "browser-mouse-guarded", "browser-navigate", "browser-reload", "browser-wheel",
        "browser-wheel-guarded", "clear-history", "clear-window-title", "client-focus", "close-pane",
        "close-provider-managed-workspace", "close-screen", "close-surface", "close-terminal",
        "close-workspace", "copy", "create-surface-with-receipt", "create-terminal", "create-workspace",
        "detach-attached-view", "detach-client", "export-layout", "focus-direction", "focus-pane",
        "get-browser-provider", "get-cell-pixels", "get-frontend-projection", "get-size-state", "identify",
        "ids", "journal-frontend-event", "list-agents", "list-clients", "list-terminals", "list-workspaces",
        "machine-listening-tcp", "machine-usage", "mark-workspaces-provider-managed", "mint-terminal-renderer",
        "mint-terminal-renderer-by-terminal", "move-tab", "move-tab-to-workspace", "move-terminal",
        "move-workspace", "new-browser-tab", "new-pane", "new-pane-right", "new-screen", "new-tab",
        "new-workspace", "note-size-activity", "notify", "pairing-response", "pane-neighbor", "paste-image",
        "ping", "process-info", "put-frontend-projection", "read-screen", "read-scrollback",
        "register-browser-provider", "release-attached-view-size", "release-surface-size", "reload-config",
        "rename-pane", "rename-provider-managed-workspace", "rename-screen", "rename-surface",
        "rename-workspace", "report-agent", "report-focus", "resize-attached-view", "resize-surface",
        "resolve-terminal", "run", "scroll-surface", "select-screen", "select-tab", "select-workspace", "send",
        "send-key", "server-stats", "set-cell-pixels", "set-client-info", "set-client-sizing",
        "set-default-colors", "set-ratio", "set-size-counts", "set-size-policy", "set-split-ratio",
        "set-terminal-idle-policy", "set-viewport-pane-width", "set-window-title", "shutdown-daemon",
        "sidebar-plugin", "split", "subscribe", "swap-pane", "terminal-events", "undo-layout",
        "unregister-browser-provider", "url-open", "url-open-claim", "url-open-result", "url-open-subscribe",
        "vt-state", "wait-for", "zoom-pane"
    ]

    /// Commands the VM daemon refused as unknown.
    final class Refused: Sendable {
        let names = Mutex<[String]>([])
    }

    /// The VM daemon: known commands answer `{}` (list-workspaces an empty
    /// tree); every other command is recorded and refused as unknown.
    static func vmDaemon(unknown: Refused) -> @Sendable ([String: JSONValue]) -> [String] {
        { request in
            let id = request["id"]?.intValue ?? 0
            let cmd = request["cmd"]?.stringValue ?? ""
            switch cmd {
            case "identify":
                let caps = capabilities.map { "\"\($0)\"" }.joined(separator: ",")
                return [#"{"id":\#(id),"ok":true,"data":{"app":"cmux-tui","version":"0.1.0","build_commit":"7d177547949b","protocol":12,"capabilities":[\#(caps)],"session":"cloud","pid":7,"registry_id":"r","generation":"g1","workspace_revision":0}}"#]
            case "list-workspaces":
                return [#"{"id":\#(id),"ok":true,"data":{"generation":"g1","registry_id":"r","workspace_revision":0,"workspaces":[]}}"#]
            case _ where commands.contains(cmd):
                return [#"{"id":\#(id),"ok":true,"data":{}}"#]
            default:
                unknown.names.withLock { $0.append(cmd) }
                return [#"{"id":\#(id),"ok":false,"error":"bad request: unknown variant `\#(cmd)`"}"#]
            }
        }
    }

    @Test func theAppSendsAnOldCloudDaemonNoCommandItDoesNotHave() async throws {
        let unknown = Refused()
        let server = try FakeDaemonServer(handler: Self.vmDaemon(unknown: unknown))
        defer { server.stop() }
        let connection = DaemonConnection(endpoint: DaemonEndpoint(socketPath: server.path))
        let identity = try await connection.start()
        #expect(DaemonCompatibility(identity: identity).level == .limited)
        _ = try? await connection.snapshot()

        // Notifications: the unread rollup and the notification ledger.
        _ = try? await connection.acknowledgeNotifications(of: 3)
        _ = try? await connection.notificationLedger()
        // Usage and Quit read per-terminal CPU and memory.
        _ = try? await connection.request(TerminalResourcesRequest(surfaces: nil))
        // Terminal lifetime and command history.
        _ = try? await connection.setTerminalKeep(.surface(3), keep: true)
        _ = try? await connection.request(SetTerminalCommandHistoryRequest(enabled: true))
        // Workspace pin and metadata, tab pin, batch close.
        _ = try? await connection.setWorkspaceMetadata("wk", pinned: true)
        _ = try? await connection.setTabPinned(3, true)
        _ = try? await connection.closeTabs([3])
        // Tab drags (each falls back to a base command on its own).
        _ = try? await connection.moveTabToSplit(3, pane: 4, edge: .right)
        _ = try? await connection.moveTabToColumn(3, target: .pane(4))
        _ = try? await connection.moveTabToNewWorkspace(3)
        _ = try? await connection.setColumnDock(of: 4, dock: nil)
        // Browser tabs the app renders itself.
        _ = try? await connection.newFrontendBrowserTab(url: "https://example.com", engine: .webkit, in: 4)
        _ = try? await connection.updateFrontendBrowserTab(3, title: "t")
        // Tab groups and saved tab groups.
        _ = try? await connection.listTabGroups()
        _ = try? await connection.createTabGroup(tabs: [3])
        _ = try? await connection.listSavedTabGroups()
        // Screen metadata and screen groups.
        _ = try? await connection.setScreenMetadata(5)
        _ = try? await connection.setScreenPinned(5, true)
        _ = try? await connection.moveScreen(5, to: 0)
        _ = try? await connection.createScreenGroup([5])
        _ = try? await connection.listSavedScreenGroups()
        // Home-only personal state, if a caller ever asks a remote machine.
        _ = try? await connection.listPersonal()
        _ = try? await connection.pinWorkspace(session: "s", key: "wk", to: "room")
        _ = try? await connection.listBookmarks(browserProfileID: "default")

        #expect(unknown.names.withLock { $0 } == [], "commands the Cloud VM daemon does not have")
        await connection.close()
    }
}
