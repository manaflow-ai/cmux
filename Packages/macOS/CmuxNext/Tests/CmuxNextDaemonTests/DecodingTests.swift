import Foundation
import Testing
@testable import CmuxNextDaemon

// Fixtures are real cmux-tui 436909bb output captured from a throwaway
// session (hostnames scrubbed).
@Suite struct DecodingTests {
    @Test func identify() throws {
        let identity = try Fixture.response(DaemonIdentity.self, "identify.json")
        #expect(identity.app == "cmux-tui")
        #expect(identity.protocolVersion == 12)
        #expect(identity.generation.rawValue.count == 36)
        for capability in DaemonCapabilities.required {
            #expect(identity.supports(capability), "missing \(capability)")
        }
    }

    @Test func treeWithColumnsSplitsAndScreens() throws {
        let tree = try Fixture.response(DaemonTree.self, "list-workspaces.json")
        #expect(tree.workspaceRevision == 3)
        #expect(tree.workspaces.map(\.name) == ["beta", "gamma"])
        let beta = tree.workspaces[0]
        #expect(beta.key == WorkspaceKey(rawValue: "c7a12f08-d868-42cd-9f98-a2ca1f6d9eb1"))
        #expect(beta.screens.count == 2)

        let screen = beta.screens[0]
        #expect(screen.columns.map(\.id) == [9, 8])
        #expect(screen.columns.map(\.width) == [1.0, 0.5])
        #expect(screen.layout.paneIDs == [4, 11, 7])
        #expect(screen.layout.splitIDs == [8, 12])
        guard case .split(let id, let direction, _, _, _) = screen.layout else {
            Issue.record("root is not a split")
            return
        }
        #expect(id == 8)
        #expect(direction == .right)
        guard case .split(_, .down, let ratio, .leaf(4), .leaf(11)) = screen.columns[0].layout else {
            Issue.record("first column is not a down split of 4/11")
            return
        }
        #expect(ratio == 0.5)

        let pane = try #require(screen.panes.first { $0.id == 4 })
        #expect(pane.tabs.count == 2)
        let tab = pane.tabs[0]
        #expect(tab.kind == .pty)
        #expect(tab.name == "main")
        #expect(tab.displayTitle == "main")
        #expect(tab.terminalID?.rawValue.count == 32)
        #expect(tab.tabResourceID?.rawValue.hasPrefix("tab_") == true)
        #expect(tab.size == CellSize(cols: 100, rows: 30)) // resized by the capture's attach
        #expect(tab.notification?.unread == true)
        #expect(tab.notification?.level == .info)
        // Proposed fields decode as absent on today's daemon.
        #expect(tab.pinned == false)
        #expect(tab.cwd == nil)
        #expect(tree.groups.isEmpty)
    }

    @Test func emptyWorkspaceHasNoScreens() throws {
        let tree = try Fixture.response(DaemonTree.self, "list-workspaces-empty.json")
        #expect(tree.workspaces.count == 1)
        #expect(tree.workspaces[0].screens.isEmpty)
    }

    @Test func mutationResults() throws {
        let workspace = try Fixture.response(WorkspaceMutationResult.self, "create-workspace.json")
        #expect(workspace.workspaceRevision == 3)
        #expect(workspace.replayed == false)
        let terminal = try Fixture.response(CreateTerminalResult.self, "create-terminal.json")
        #expect(terminal.lifecycle == "running")
        #expect(terminal.surface == 3)
        let projection = try Fixture.response(FrontendProjection.self, "put-projection.json")
        #expect(projection.projectionRevision == 1)
        #expect(projection.projection["sidebar"]?.doubleValue == 240)
    }

    @Test func everyCapturedEventDecodesToATypedCase() throws {
        var names: [String] = []
        for line in try Fixture.lines("events.jsonl") {
            let name = try #require(Fixture.eventName(line))
            let event = DaemonEvent.decode(name: name, line: line)
            if case .unknown = event { Issue.record("\(name) decoded as unknown") }
            names.append(name)
        }
        #expect(names.contains("tab-added"))
        #expect(names.last == "daemon-shutdown")
    }

    @Test func tabDeltaAndWorkspaceDeltaPayloads() throws {
        let events = try Fixture.lines("events.jsonl").map { DaemonEvent.decode(name: Fixture.eventName($0)!, line: $0) }
        let added = events.compactMap { if case .tabAdded(let delta) = $0 { delta } else { nil } }.first
        #expect(added?.pane == 4)
        #expect(added?.index == 1)
        #expect(added?.entity.surface == 13)
        let workspace = events.compactMap { if case .workspaceAdded(let delta) = $0 { delta } else { nil } }.first
        #expect(workspace?.workspaceRevision == 3)
        #expect(workspace?.mutationID == "m4")
        #expect(workspace?.entity.name == "gamma")
        let notification = events.compactMap { if case .notification(let n) = $0 { n } else { nil } }.first
        #expect(notification?.surface == 3)
        #expect(notification?.title == "Build")
    }

    @Test func attachStreamDecodesToChannelEvents() throws {
        let events = try Fixture.lines("attach.jsonl").compactMap {
            TerminalAttachment.decodeAttachEvent(name: Fixture.eventName($0)!, line: $0, surface: 3)
        }
        guard case .replay(let replay) = events.first else {
            Issue.record("stream does not start with a replay")
            return
        }
        #expect(replay.cols == 80)
        #expect(replay.rows == 24)
        #expect(replay.colors?.cursorStyle == "bar")
        #expect(replay.kittyGraphicsState?.replayCursorOffset == 341)
        var output = Data()
        var resized: TerminalReplay?
        for event in events {
            switch event {
            case .output(let data, _): output.append(data)
            case .resized(let replay): resized = replay
            default: break
            }
        }
        #expect(String(decoding: output, as: UTF8.self).contains("hi-from-probe"))
        #expect(resized?.cols == 100)
        #expect(resized?.rows == 30)
        #expect(resized.map { String(decoding: $0.data, as: UTF8.self).contains("hi-from-probe") } == true)
        // Events for another surface are ignored.
        let other = try Fixture.lines("attach.jsonl").compactMap {
            TerminalAttachment.decodeAttachEvent(name: Fixture.eventName($0)!, line: $0, surface: 99)
        }
        #expect(other.isEmpty)
    }

    /// `terminal-pending-sequence-v1`: the unfinished sequence travels apart
    /// from the replay on `vt-state` and `resized`.
    @Test func replaysCarryTheirPendingSequence() {
        let pending = Data("\u{1B}[1;3".utf8).base64EncodedString()
        let data = Data("prompt$ ".utf8).base64EncodedString()
        let initial = Data(#"{"event":"vt-state","surface":3,"cols":80,"rows":24,"data":"\#(data)","pending":"\#(pending)"}"#.utf8)
        guard case .replay(let replay) = TerminalAttachment.decodeAttachEvent(name: "vt-state", line: initial, surface: 3) else {
            Issue.record("expected a replay")
            return
        }
        #expect(replay.data == Data("prompt$ ".utf8))
        #expect(replay.pending == Data("\u{1B}[1;3".utf8))
        let resize = Data(#"{"event":"resized","surface":3,"cols":90,"rows":28,"replay":"\#(data)","pending":"\#(pending)"}"#.utf8)
        guard case .resized(let resized) = TerminalAttachment.decodeAttachEvent(name: "resized", line: resize, surface: 3) else {
            Issue.record("expected a resize")
            return
        }
        #expect(resized.pending == Data("\u{1B}[1;3".utf8))
        let boundary = Data(#"{"event":"vt-state","surface":3,"cols":80,"rows":24,"data":"\#(data)"}"#.utf8)
        guard case .replay(let plain) = TerminalAttachment.decodeAttachEvent(name: "vt-state", line: boundary, surface: 3) else {
            Issue.record("expected a replay")
            return
        }
        #expect(plain.pending.isEmpty)
    }

    @Test func unknownEventsAndFieldsAreTolerated() throws {
        let line = Data(#"{"event":"group-added","group":{"key":"g1","name":"Work"},"future":true}"#.utf8)
        guard case .unknown(let name, let payload) = DaemonEvent.decode(name: "group-added", line: line) else {
            Issue.record("expected unknown")
            return
        }
        #expect(name == "group-added")
        #expect(payload["group"]?["name"]?.stringValue == "Work")

        let tab = try JSONDecoder().decode(TabSnapshot.self, from: Data(
            #"{"surface":1,"kind":"future-kind","new_field":[1]}"#.utf8))
        #expect(tab.kind == .other("future-kind"))
        #expect(tab.title == "")
        #expect(!tab.isFrontendOwned)
    }

    /// Shapes from the feat-cmux-next-daemon branch spec (workspace-groups-v1,
    /// workspace-metadata-v1, tab-metadata-v1, frontend-browser-tabs-v1).
    @Test func daemonBranchFields() throws {
        let tree = try JSONDecoder().decode(DaemonTree.self, from: Data(#"""
        {"workspace_revision":4,
         "groups":[{"id":"agents","name":"Agents","color":"gray","collapsed":true,"index":0}],
         "workspaces":[{"id":1,"key":"k1","name":"api","group":"agents","color":"#ff8800","icon":"terminal","title":"API","active":true,
           "screens":[{"id":2,"active":true,"active_pane":3,"zoomed_pane":null,"layout":{"type":"leaf","pane":3},
             "panes":[{"id":3,"name":null,"active_tab":0,"tabs":[
               {"surface":4,"kind":"pty","name":null,"title":"zsh","size":null,"dead":false,"pinned":true,"cwd":"/repo","git_branch":"a1b2c3d","git_detached":true,"browser_renderer":null},
               {"surface":5,"kind":"browser","name":null,"title":"Docs","size":null,"dead":false,"pinned":false,"cwd":null,"git_branch":null,"git_detached":false,
                "browser_renderer":"frontend","browser_engine":"cef","favicon_url":"https://x/f.ico","browser_profile_id":"p1","url":"https://x"}]}]}]}]}
        """#.utf8))
        #expect(tree.groups == [WorkspaceGroupSnapshot(id: "agents", name: "Agents", color: "gray", collapsed: true, index: 0)])
        let workspace = tree.workspaces[0]
        #expect(workspace.group == "agents")
        #expect(workspace.displayName == "API")
        #expect(workspace.icon == "terminal")
        let tabs = workspace.screens[0].panes[0].tabs
        #expect(tabs[0].pinned && tabs[0].gitDetached)
        #expect(tabs[0].gitBranch == "a1b2c3d")
        #expect(tabs[0].cwd == "/repo")
        #expect(tabs[1].isFrontendOwned)
        #expect(tabs[1].browserEngine == "cef")
        #expect(tabs[1].faviconURL == "https://x/f.ico")

        let changed = Data(#"{"event":"tab-changed","workspace":1,"screen":2,"pane":3,"surface":4,"index":0,"entity":{"surface":4,"kind":"pty","title":"zsh","pinned":false}}"#.utf8)
        guard case .tabChanged(let delta) = DaemonEvent.decode(name: "tab-changed", line: changed) else {
            Issue.record("tab-changed did not decode")
            return
        }
        #expect(delta.entity.pinned == false)
        let workspaceChanged = Data(#"{"event":"workspace-changed","workspace":1,"index":0,"entity":{"id":1,"key":"k1","name":"api","color":null,"icon":null,"title":null,"active":true,"screens":[]},"workspace_revision":5,"registry_id":"r","generation":"g"}"#.utf8)
        guard case .workspaceChanged(let wdelta) = DaemonEvent.decode(name: "workspace-changed", line: workspaceChanged) else {
            Issue.record("workspace-changed did not decode")
            return
        }
        #expect(wdelta.workspaceRevision == 5)
    }
}
