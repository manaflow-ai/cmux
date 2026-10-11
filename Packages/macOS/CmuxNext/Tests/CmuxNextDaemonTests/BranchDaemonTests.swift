import Foundation
import Testing
@testable import CmuxNextDaemon

/// End-to-end checks of the cmux-tui PR 15518 commands against the hosted
/// build of this checkout's cmux-tui tree (`scripts/cmux-next/pin-cmux-tui.sh
/// fetch`) or `CMUX_NEXT_TUI_BIN`. Release clients lack these commands, so the
/// suite is disabled for them.
@Suite(.enabled(if: RealBinary.isBranchBuild, "needs the same-tree cmux-tui (scripts/cmux-next/pin-cmux-tui.sh fetch)"),
       .timeLimit(.minutes(2)), .liveDaemon)
struct BranchDaemonTests {
    /// The same-tree daemon serves every capability the app relies on
    /// (scripts/cmux-next/check-daemon-capabilities.sh checks the bundle the
    /// same way), and none the app still lists as unserved.
    @Test func advertisesEveryCmuxNextCapability() async throws {
        try await BranchDaemonHarness.with { h in
            let capabilities = DaemonCapabilities.shared
            let missing = (capabilities.required + capabilities.optional).filter { !h.identity.supports($0) }
            #expect(missing.isEmpty, "missing: \(missing)")
            let nowServed = capabilities.unservedByBundledDaemon.filter { h.identity.supports($0) }
            #expect(nowServed.isEmpty, "served now, move to optional: \(nowServed)")
        }
    }

    /// Workspace groups are personal: the home session's v2
    /// `workspace_group.*` and `workspace.place` (the shared group commands
    /// are not used), mirrored through `personal-changed`.
    @Test func personalWorkspaceGroupsCreatePlaceCollapse() async throws {
        try await BranchDaemonHarness.with(sessionEvents: true) { h in
            try await h.store.waitUntil("state resources") { h.store.servesStateResources }
            let a = try await h.connection.createWorkspace(name: "a")
            let b = try await h.connection.createWorkspace(name: "b")
            let agents = try await h.connection.state.createWorkspaceGroup(name: "Agents", room: nil, color: "blue")
            let infra = try await h.connection.state.createWorkspaceGroup(name: "Infra", room: nil, color: nil)
            try await h.store.waitUntil("workspaces mirrored") {
                h.store.workspace(key: a.key)?.resourceID != nil && h.store.workspace(key: b.key)?.resourceID != nil
            }
            let session = try #require(await h.store.registryID)
            for key in [b.key, a.key] {
                let resource = await h.store.personalStateID(session: session, key: key)
                #expect(resource != nil)
                try await h.connection.state.placePersonalWorkspace(session: session, key: key, resource: resource,
                                                              group: .set(WorkspaceGroupID(rawValue: agents.id)), index: 0)
            }
            try await h.connection.state.updateWorkspaceGroup(agents.id, collapsed: true)
            try await h.connection.state.moveWorkspaceGroup(infra.id, to: 0)
            try await h.store.waitUntil("personal groups mirrored") {
                let groups = h.store.personal.groups
                let members = h.store.personal.workspaces.filter { $0.group?.rawValue == agents.id }.map(\.workspaceKey)
                return groups.first { $0.id.rawValue == agents.id }?.collapsed == true
                    && Set(members) == [a.key, b.key]
            }
            try await h.connection.state.deleteWorkspaceGroup(agents.id)
            try await h.store.waitUntil("group deleted") { h.store.personal.group(WorkspaceGroupID(rawValue: agents.id)) == nil }
        }
    }

    @Test func workspaceMetadataAndPinnedTabs() async throws {
        try await BranchDaemonHarness.with { h in
            let (key, pane, first) = try await h.workspaceWithTerminal("meta")
            let metadata = try await h.connection.setWorkspaceMetadata(key, color: .set("green"), icon: .set("terminal"),
                                                                      title: .set("Build"))
            #expect(metadata.color == "green")
            #expect(metadata.changed)
            let second = try await h.connection.newTab(in: pane).surface
            let pinned = try await h.connection.setTabPinned(second, true)
            #expect(pinned.pinned)
            #expect(pinned.index == 0)
            #expect(pinned.changed)
            let order = try #require(try await h.pane(of: first)).tabs
            #expect(order.map(\.surface) == [second, first])
            #expect(order.first?.pinned == true)
            // The shell reports its directory after it starts; `tab-changed`
            // carries it.
            try await h.store.waitUntil("pinned tab reports its cwd") { h.store.tab(surface: second)?.cwd != nil }
            let workspace = try #require(try await h.tree().workspaces.first { $0.key == key })
            #expect(workspace.displayName == "Build")
            #expect(workspace.icon == "terminal")
            try await h.store.waitUntil("store sees the pin") { h.store.tab(surface: second)?.pinned == true }
        }
    }

    @Test func tabGroupsCreateColorCollapseSaveReopen() async throws {
        try await BranchDaemonHarness.with { h in
            let (_, pane, a) = try await h.workspaceWithTerminal("groups")
            let b = try await h.connection.newTab(in: pane).surface
            let c = try await h.connection.newTab(in: pane).surface

            let created = try await h.connection.createTabGroup(in: pane, tabs: [a, b], name: "API", color: "green",
                                                                transaction: .generate())
            let group = try #require(created.group)
            #expect(group.name == "API")
            #expect(created.surfaces == [a, b])
            #expect(created.pane == pane)

            let updated = try await h.connection.updateTabGroup(group.id, color: .set("purple"), collapsed: true)
            #expect(updated.group?.color == "purple")
            #expect(updated.group?.collapsed == true)

            // `index` places the added tab inside the run.
            _ = try await h.connection.addTabs([c], toGroup: group.id, index: 0)
            var strip = try #require(try await h.pane(of: a))
            let run = try #require(strip.tabGroups.first { $0.id == group.id })
            #expect(run.surfaces == [c, a, b])
            #expect(run.color == "purple")
            #expect(run.collapsed)
            #expect(strip.tabs.allSatisfy { $0.tabGroup == group.id })

            let saved = try await h.connection.saveTabGroup(group.id)
            #expect(saved.name == "API")
            #expect(saved.tabs.count == 3)
            #expect(saved.tabs.allSatisfy { $0.kind == .pty && $0.terminalID != nil })
            try await h.store.waitUntil("store links the saved group") {
                h.store.savedTabGroups.first { $0.id == saved.id }?.openGroup == group.id
            }

            let closed = try await h.connection.closeTabGroup(group.id)
            #expect(Set(closed.closed) == [a, b, c])
            #expect(closed.groupID == group.id)
            #expect(try await h.connection.listSavedTabGroups().map(\.id) == [saved.id])

            let host = try await h.connection.newTab(in: nil)
            let hostPane = try #require(try await h.pane(of: host.surface)).id
            let reopened = try await h.connection.reopenSavedTabGroup(saved.id, in: hostPane, transaction: .generate())
            let restored = try #require(reopened.group)
            #expect(restored.savedID == saved.id)
            #expect(reopened.surfaces.count == 3)
            strip = try #require(try await h.pane(of: host.surface))
            // Running terminals reattach: the restored tabs show the saved terminals.
            let terminals = Set(strip.tabs.filter { $0.tabGroup == restored.id }.compactMap(\.terminalID))
            #expect(terminals == Set(saved.tabs.compactMap(\.terminalID)))

            #expect(try await h.connection.unsaveTabGroup(group: restored.id))
            #expect(try await h.connection.listSavedTabGroups().isEmpty)
            let ungrouped = try await h.connection.ungroupTabGroup(restored.id)
            #expect(ungrouped.surfaces.count == 3)
        }
    }

    @Test func frontendBrowserTabCreateAndUpdate() async throws {
        try await BranchDaemonHarness.with { h in
            let (_, pane, _) = try await h.workspaceWithTerminal("browser")
            let created = try await h.connection.newFrontendBrowserTab(url: "https://example.com/", engine: .webkit, in: pane,
                                                                       title: "Example", profileID: "default")
            var tab = try #require(try await h.tab(created.surface))
            #expect(tab.kind == .browser)
            #expect(tab.isFrontendOwned)
            #expect(tab.browserEngine == "webkit")
            #expect(tab.browserProfileID == "default")
            let updated = try await h.connection.updateFrontendBrowserTab(created.surface, url: "https://example.org/", title: "Org",
                                                                         faviconURL: .set("https://example.org/favicon.ico"))
            #expect(updated.changed)
            #expect(updated.url == "https://example.org/")
            tab = try #require(try await h.tab(created.surface))
            #expect(tab.url == "https://example.org/")
            #expect(tab.faviconURL == "https://example.org/favicon.ico")
            try await h.store.waitUntil("store sees the navigation") {
                h.store.tab(surface: created.surface)?.url == "https://example.org/"
            }
        }
    }

    @Test func tabDragCommandsEchoTheirTransaction() async throws {
        try await BranchDaemonHarness.with { h in
            let (_, pane, a) = try await h.workspaceWithTerminal("drag")
            let b = try await h.connection.newTab(in: pane).surface
            let c = try await h.connection.newTab(in: pane).surface

            let toSplit = ClientTransactionID.generate()
            let split = try await h.connection.moveTabToSplit(b, pane: pane, edge: .right, transaction: toSplit)
            #expect(split.undoable)
            #expect(split.pane != pane)
            #expect(try await h.pane(of: b)?.id == split.pane)

            let toColumn = ClientTransactionID.generate()
            let column = try await h.connection.moveTabToColumn(c, target: .pane(pane), transaction: toColumn)
            #expect(try await h.pane(of: c)?.id == column.pane)
            #expect(try await h.tree().workspaces.flatMap(\.screens).contains { !$0.columns.isEmpty })

            let toWorkspace = ClientTransactionID.generate()
            let moved = try await h.connection.moveTabToNewWorkspace(a, transaction: toWorkspace)
            #expect(moved.key != nil)
            #expect(try await h.tree().workspaces.first { $0.key == moved.key }?.screens.first?.panes.first?.tabs.map(\.surface) == [a])

            try await h.store.waitUntil("every drag echoed its transaction") {
                Set([toSplit, toColumn, toWorkspace]).isSubset(of: Set(h.store.confirmedTransactions))
            }
        }
    }

    @Test func ackTabNotificationsClearsTheMarker() async throws {
        try await BranchDaemonHarness.with { h in
            let (key, _, surface) = try await h.workspaceWithTerminal("ack")
            _ = try await h.connection.notify(title: "Build finished", body: "ok", surface: surface)
            try await h.store.waitUntil("marker is unread") { h.store.tab(surface: surface)?.notification?.unread == true }
            #expect(try await h.tree().workspaces.first { $0.key == key }?.unreadCount == 1)

            let ack = try await h.connection.acknowledgeNotifications(of: surface)
            #expect(ack.cleared)
            #expect(ack.acknowledged.count == 1)
            #expect(try await h.tab(surface)?.notification?.unread != true)
            #expect(try await h.tree().workspaces.first { $0.key == key }?.unreadCount == 0)
            #expect(try await h.connection.notificationLedger().first?.acknowledged == true)
            #expect(try await h.connection.acknowledgeNotifications(of: surface).cleared == false)
        }
    }

    /// The daemon process and each terminal get only the allowlist. A secret
    /// in the app's and the login shell's environment reaches neither the
    /// shell nor the daemon's on-disk creation receipt.
    @Test func terminalsSeeTheAllowlistAndNoParentSecret() async throws {
        let process = ProcessInfo.processInfo.environment
        var base: [String: String] = ["CNIT_SECRET_TOKEN": "hunter2-app", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        for key in ["HOME", "USER", "LOGNAME", "SHELL", "TMPDIR"] { base[key] = process[key] }
        let login: [String: String] = [
            "PATH": "/opt/cnit/bin:/usr/bin:/bin", "LC_CNIT": "probe-lc", "XDG_CNIT_DIR": "/cnit/xdg",
            "CMUX_CNIT": "probe-cmux", "CNIT_SECRET_TOKEN": "hunter2-login", "GITHUB_TOKEN": "hunter2-gh",
        ]
        let daemonEnvironment = LoginEnvironment.shared.daemonEnvironment(login: login, base: base, overrides: [:])
        #expect(daemonEnvironment["CNIT_SECRET_TOKEN"] == nil)
        // Per-terminal env differs from the daemon's, so the shell proves `env` arrived.
        var terminalEnvironment = TerminalEnvironment.instance.terminal(login: login, base: base)
        terminalEnvironment["LC_CNIT_TERMINAL"] = "probe-terminal"
        let fixedTerminalEnvironment = terminalEnvironment
        try await BranchDaemonHarness.with(daemonEnvironment: daemonEnvironment, terminalEnvironment: { fixedTerminalEnvironment }) { h in
            let (_, pane, _) = try await h.workspaceWithTerminal("env")
            let tab = try await h.connection.newTab(in: pane).surface
            let output = try await h.run(
                "env | grep -E '^(LC_CNIT|XDG_CNIT|CMUX_CNIT|CNIT_SECRET|GITHUB_TOKEN)' | sed 's/^/ENV:/'; echo DONE-$((40+2))",
                in: tab, until: "DONE-42")
            let lines = Set(output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.hasPrefix("ENV:") })
            #expect(lines.contains("ENV:LC_CNIT=probe-lc"), "output: \(output)")
            #expect(lines.contains("ENV:LC_CNIT_TERMINAL=probe-terminal"), "output: \(output)")
            #expect(lines.contains("ENV:XDG_CNIT_DIR=/cnit/xdg"))
            #expect(lines.contains("ENV:CMUX_CNIT=probe-cmux"))
            #expect(!output.contains("hunter2"), "secret leaked: \(output)")

            // The receipt keeps `env` on disk: the allowlisted probe is there, the secret is not.
            let stateFiles = FileManager.default.enumerator(at: h.root, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL } ?? []
            let blobs = stateFiles.compactMap { try? Data(contentsOf: $0) }
            #expect(blobs.contains { $0.range(of: Data("probe-terminal".utf8)) != nil })
            #expect(!blobs.contains { $0.range(of: Data("hunter2".utf8)) != nil })
        }
    }
}
