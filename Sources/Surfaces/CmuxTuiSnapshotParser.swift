import CoreFoundation
import Foundation

/// Maps a cmux-tui public session snapshot (`session current snapshot --json`) onto
/// ``SurfaceResource`` values for one cloud machine. Pure and total: unknown keys are
/// ignored, a malformed entry drops that entry, never the machine.
///
/// Snapshot keys (cmux-tui `crates/cmux-tui-core/src/resource_api.rs`,
/// `public_session_snapshot_with_journal_head` / `public_terminal_snapshot`):
/// `workspaces[{id,name,focused}]`, `screens[{id,workspace_id}]`, `panes[{id,screen_id}]`,
/// `tabs[{id,pane_id,name,content_kind,content_id}]`,
/// `terminals[{id,tab_id,title,cwd?,lifecycle}]`, `agents[{terminal_id,state,source}]`.
/// A tab's `name` is the user-set label (`tab.rename`, persisted in the daemon's
/// registry); the terminal's `title` is PTY-derived. A named view wins over the title.
struct CmuxTuiSnapshotParser: Sendable {
    /// Chooses a stable destination for projecting a terminal that currently has no remote
    /// tab view. The session snapshot lists structural records separately, so selection walks
    /// the focused workspace, focused screen, and focused pane in that order, falling back to
    /// canonical array order at each level. A new tab is appended to the chosen pane.
    static func terminalProjectionTarget(from snapshot: [String: Any]) -> CloudTuiTerminalProjectionTarget? {
        let workspaces = snapshot["workspaces"] as? [[String: Any]] ?? []
        let screens = snapshot["screens"] as? [[String: Any]] ?? []
        let panes = snapshot["panes"] as? [[String: Any]] ?? []
        let tabs = snapshot["tabs"] as? [[String: Any]] ?? []
        var tabCountByPane: [String: Int] = [:]
        for tab in tabs {
            if let paneID = tab["pane_id"] as? String, !paneID.isEmpty {
                tabCountByPane[paneID, default: 0] += 1
            }
        }
        // Prefer focused records, but do not strand a pool terminal when the focused
        // workspace/screen was intentionally left empty. The first candidate with a live
        // pane is the safe destination; all arrays are already in daemon canonical order.
        let orderedWorkspaces = workspaces.enumerated().sorted { left, right in
            let leftFocused = (left.element["focused"] as? Bool) == true
            let rightFocused = (right.element["focused"] as? Bool) == true
            return leftFocused != rightFocused ? leftFocused : left.offset < right.offset
        }
        for workspaceEntry in orderedWorkspaces {
            guard let workspaceID = workspaceEntry.element["id"] as? String, !workspaceID.isEmpty else { continue }
            let workspaceScreens = screens.enumerated().filter {
                ($0.element["workspace_id"] as? String) == workspaceID
            }.sorted { left, right in
                let leftFocused = (left.element["focused"] as? Bool) == true
                let rightFocused = (right.element["focused"] as? Bool) == true
                return leftFocused != rightFocused ? leftFocused : left.offset < right.offset
            }
            for screenEntry in workspaceScreens {
                guard let screenID = screenEntry.element["id"] as? String, !screenID.isEmpty else { continue }
                let screenPanes = panes.enumerated().filter {
                    ($0.element["screen_id"] as? String) == screenID
                }.sorted { left, right in
                    let leftFocused = (left.element["focused"] as? Bool) == true
                    let rightFocused = (right.element["focused"] as? Bool) == true
                    return leftFocused != rightFocused ? leftFocused : left.offset < right.offset
                }
                for paneEntry in screenPanes {
                    guard let paneID = paneEntry.element["id"] as? String, !paneID.isEmpty else { continue }
                    return CloudTuiTerminalProjectionTarget(
                        workspaceID: workspaceID,
                        screenID: screenID,
                        paneID: paneID,
                        index: tabCountByPane[paneID] ?? 0
                    )
                }
            }
        }
        return nil
    }

    /// Returns the decimal resource revision carried by a public session
    /// snapshot. It is used as an optimistic-concurrency fence when a detached
    /// terminal is projected into a pane selected from that snapshot.
    static func resourceRevision(from snapshot: [String: Any]) -> String? {
        guard let cursor = snapshot["cursor"] as? [String: Any] else { return nil }
        if let revision = cursor["revision"] as? String,
           !revision.isEmpty,
           revision.allSatisfy(\.isNumber) {
            return revision
        }
        if let revision = cursor["revision"] as? NSNumber,
           CFGetTypeID(revision) != CFBooleanGetTypeID() {
            let type = String(cString: revision.objCType)
            switch type {
            case "c", "s", "i", "l", "q":
                let value = revision.int64Value
                return value >= 0 ? String(value) : nil
            case "C", "S", "I", "L", "Q":
                return String(revision.uint64Value)
            default:
                return nil
            }
        }
        return nil
    }

    /// Builds the one lossless state value consumed by every cloud projection.
    /// A missing cursor is accepted by the legacy resource helpers, but never
    /// becomes a synchronizable state because it cannot be ordered against an
    /// event stream.
    static func state(fromSnapshot snapshot: [String: Any], machine: SurfaceMachineID) -> CloudVMState? {
        guard let cursor = CloudVMCursor(snapshot: snapshot),
              let rawSnapshot = canonicalJSONData(snapshot),
              identityCollectionsAreUnique(in: snapshot)
        else { return nil }

        let workspaces = ((snapshot["workspaces"] as? [[String: Any]]) ?? []).enumerated().compactMap { index, raw -> CloudVMWorkspaceState? in
            guard let id = nonEmptyString(raw["id"]) else { return nil }
            return CloudVMWorkspaceState(
                id: id,
                name: nonEmptyString(raw["name"]) ?? id,
                index: integer(raw["index"]) ?? index,
                focused: raw["focused"] as? Bool ?? false
            )
        }
        let screens = ((snapshot["screens"] as? [[String: Any]]) ?? []).enumerated().compactMap { index, raw -> CloudVMScreenState? in
            guard let id = nonEmptyString(raw["id"]), let workspaceID = nonEmptyString(raw["workspace_id"]) else { return nil }
            return CloudVMScreenState(
                id: id,
                workspaceID: workspaceID,
                name: nonEmptyString(raw["name"]),
                index: integer(raw["index"]) ?? index,
                focused: raw["focused"] as? Bool ?? false,
                layout: raw["layout"].flatMap(canonicalJSONData)
            )
        }
        let tabs = ((snapshot["tabs"] as? [[String: Any]]) ?? []).enumerated().compactMap { index, raw -> CloudVMTabState? in
            guard let id = nonEmptyString(raw["id"]), let paneID = nonEmptyString(raw["pane_id"]) else { return nil }
            guard let contentKind = nonEmptyString(raw["content_kind"]), let contentID = nonEmptyString(raw["content_id"]) else { return nil }
            let name = nonEmptyString(raw["name"])
            return CloudVMTabState(
                id: id,
                paneID: paneID,
                name: name,
                index: integer(raw["index"]) ?? index,
                focused: raw["focused"] as? Bool ?? false,
                contentKind: contentKind,
                contentID: contentID
            )
        }
        // The public daemon schema puts the relationship on `tabs[].pane_id`.
        // `panes[].tab_ids` is not part of that schema, so reading it would make
        // every typed pane appear empty and would create a false second source of
        // placement truth. Derive the index from the already parsed tabs instead.
        var tabIDsByPane: [String: [String]] = [:]
        for tab in tabs {
            tabIDsByPane[tab.paneID, default: []].append(tab.id)
        }
        let panes = ((snapshot["panes"] as? [[String: Any]]) ?? []).compactMap { raw -> CloudVMPaneState? in
            guard let id = nonEmptyString(raw["id"]), let screenID = nonEmptyString(raw["screen_id"]) else { return nil }
            return CloudVMPaneState(
                id: id,
                screenID: screenID,
                name: nonEmptyString(raw["name"]),
                focused: raw["focused"] as? Bool ?? false,
                zoomed: raw["zoomed"] as? Bool ?? false,
                tabIDs: tabIDsByPane[id] ?? []
            )
        }
        let terminals = ((snapshot["terminals"] as? [[String: Any]]) ?? []).compactMap { raw -> CloudVMTerminalState? in
            guard let id = nonEmptyString(raw["id"]) else { return nil }
            var tabIDs = uniquePreservingOrder((raw["tab_ids"] as? [String]) ?? [])
            if tabIDs.isEmpty, let tabID = nonEmptyString(raw["tab_id"]) { tabIDs = [tabID] }
            return CloudVMTerminalState(
                id: id,
                tabIDs: tabIDs,
                title: (raw["title"] as? String) ?? "",
                cwd: nonEmptyString(raw["cwd"]),
                lifecycle: (raw["lifecycle"] as? String) ?? ((raw["running"] as? Bool) == true ? "running" : "exited"),
                cols: integer(raw["cols"]),
                rows: integer(raw["rows"]),
                running: raw["running"] as? Bool
            )
        }
        let browsers = ((snapshot["browsers"] as? [[String: Any]]) ?? []).compactMap { raw -> CloudVMBrowserState? in
            guard let id = nonEmptyString(raw["id"]), let tabID = nonEmptyString(raw["tab_id"]) else { return nil }
            return CloudVMBrowserState(
                id: id,
                tabID: tabID,
                url: (raw["url"] as? String) ?? "",
                title: (raw["title"] as? String) ?? "",
                status: (raw["status"] as? String) ?? ""
            )
        }
        let agents = ((snapshot["agents"] as? [[String: Any]]) ?? []).compactMap { raw -> CloudVMAgentState? in
            guard let terminalID = nonEmptyString(raw["terminal_id"]), let state = nonEmptyString(raw["state"]) else { return nil }
            return CloudVMAgentState(id: nonEmptyString(raw["id"]), terminalID: terminalID, state: state, source: nonEmptyString(raw["source"]))
        }

        let typedKinds: Set<String> = ["workspaces", "screens", "panes", "tabs", "terminals", "browsers", "agents"]
        // `cursor` orders the document; it is metadata, not an entity. Keeping
        // it in `otherEntities` would expose a nil-id pseudo-resource and make
        // an agent treat the ordering token as mutable VM state.
        let metadataKinds: Set<String> = ["cursor"]
        var otherEntities: [CloudVMEntity] = []
        for (kind, value) in snapshot {
            guard !typedKinds.contains(kind), !metadataKinds.contains(kind) else { continue }
            if let object = value as? [String: Any] {
                otherEntities.append(contentsOf: entityValues(kind: kind, objects: [object]))
            } else if let objects = value as? [[String: Any]] {
                otherEntities.append(contentsOf: entityValues(kind: kind, objects: objects))
            }
        }
        // JSON object enumeration is intentionally unordered. Keep the opaque
        // index stable so an agent can diff two exports without noise.
        otherEntities.sort {
            if $0.kind != $1.kind { return $0.kind < $1.kind }
            let leftID = $0.id ?? ""
            let rightID = $1.id ?? ""
            if leftID != rightID { return leftID < rightID }
            return $0.payload.lexicographicallyPrecedes($1.payload)
        }

        return CloudVMState(
            machine: machine,
            cursor: cursor,
            rawSnapshot: rawSnapshot,
            workspaces: workspaces,
            screens: screens,
            panes: panes,
            tabs: tabs,
            terminals: terminals,
            browsers: browsers,
            agents: agents,
            otherEntities: otherEntities
        )
    }

    /// A remote graph is keyed by daemon IDs. Silently choosing the first or last
    /// duplicate would make a rename or projection target depend on wire order.
    /// Reject duplicate identity rows at the synchronization boundary so the
    /// provider takes its bounded full-snapshot recovery path instead.
    private static func identityCollectionsAreUnique(in snapshot: [String: Any]) -> Bool {
        for key in ["workspaces", "screens", "panes", "tabs", "terminals", "browsers"] {
            guard let raw = snapshot[key] else { continue }
            guard let rows = raw as? [[String: Any]] else { return false }
            var ids = Set<String>()
            for row in rows {
                guard let id = nonEmptyString(row["id"]) else { continue }
                guard ids.insert(id).inserted else { return false }
            }
        }
        return true
    }

    private static func uniquePreservingOrder(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Re-derives the compatibility resources from the exact state bytes. No
    /// resource mutation path is allowed to maintain a second remote graph.
    static func resources(from state: CloudVMState) -> [SurfaceResource] {
        guard let snapshot = state.snapshotObject() else { return [] }
        return resources(fromSnapshot: snapshot, machine: state.machine)
    }

    /// Applies one contiguous `session.delta` batch to the complete raw graph,
    /// then rebuilds every typed index from that one result. Upserts replace an
    /// entity in place, deletes remove it, and unknown resource kinds refuse the
    /// batch so the caller can fetch a fresh snapshot.
    static func applying(
        deltaPayload: Data,
        cursor: CloudVMCursor,
        to state: CloudVMState
    ) -> CloudVMState? {
        guard var snapshot = state.snapshotObject(),
              let delta = try? JSONSerialization.jsonObject(with: deltaPayload) as? [String: Any],
              let changes = delta["changes"] as? [[String: Any]]
        else { return nil }

        for change in changes {
            guard let kind = nonEmptyString(change["kind"]),
                  let resource = nonEmptyString(change["resource"]),
                  let id = nonEmptyString(change["id"]),
                  let storage = deltaStorage(for: resource)
            else { return nil }

            switch kind {
            case "upsert":
                guard let value = change["value"] as? [String: Any],
                      nonEmptyString(value["id"]) == id else { return nil }
                switch storage {
                case .single(let key):
                    snapshot[key] = value
                case .collection(let key):
                    var values = (snapshot[key] as? [[String: Any]]) ?? []
                    if let index = values.firstIndex(where: { nonEmptyString($0["id"]) == id }) {
                        values[index] = value
                    } else {
                        values.append(value)
                    }
                    snapshot[key] = values
                }
            case "delete":
                switch storage {
                case .single(let key):
                    // machine and session are required roots of a resource
                    // snapshot. Their deletion ends the document, so applying
                    // an NSNull tombstone would create a fake, partially valid
                    // graph. Force a full snapshot instead.
                    guard key != "machine", key != "session" else { return nil }
                    if let value = snapshot[key] as? [String: Any], nonEmptyString(value["id"]) == id {
                        snapshot[key] = NSNull()
                    }
                case .collection(let key):
                    var values = (snapshot[key] as? [[String: Any]]) ?? []
                    values.removeAll { nonEmptyString($0["id"]) == id }
                    snapshot[key] = values
                }
            default:
                return nil
            }
        }
        snapshot["cursor"] = [
            "generation": cursor.generation,
            "revision": String(cursor.revision),
        ]
        return Self.state(fromSnapshot: snapshot, machine: state.machine)
    }

    /// Legacy entry point retained for callers that only have a one-shot snapshot.
    static func terminals(fromSnapshot snapshot: [String: Any], machine: SurfaceMachineID) -> [SurfaceResource] {
        resources(fromSnapshot: snapshot, machine: machine)
    }

    /// Decodes the snapshot used by a detached-terminal projection away from
    /// the UI actor. The returned revision is the same cursor that guards the
    /// subsequent topology mutation.
#if compiler(>=6.2)
    @concurrent
#else
    @Sendable
#endif
    nonisolated static func terminalProjectionTarget(
        from data: Data
    ) async -> (target: CloudTuiTerminalProjectionTarget, revision: String?)? {
        guard let snapshot = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let target = terminalProjectionTarget(from: snapshot) else {
            return nil
        }
        return (target, resourceRevision(from: snapshot))
    }

    /// Terminal resources in the daemon's workspace order, each carrying every view of it
    /// (`tab_ids` joined through tabs → panes → screens → workspaces). A terminal with no
    /// resolvable view keeps an empty view list: it is alive in the machine's pool, not
    /// attributed to a workspace it is not in.
    private static func resources(fromSnapshot snapshot: [String: Any], machine: SurfaceMachineID) -> [SurfaceResource] {
        let screensRaw = (snapshot["screens"] as? [[String: Any]]) ?? []
        let panesRaw = (snapshot["panes"] as? [[String: Any]]) ?? []
        let tabsRaw = (snapshot["tabs"] as? [[String: Any]]) ?? []
        let terminalsRaw = (snapshot["terminals"] as? [[String: Any]]) ?? []
        let agentsRaw = (snapshot["agents"] as? [[String: Any]]) ?? []

        var workspaceOfScreen: [String: String] = [:]
        for screen in screensRaw {
            if let id = screen["id"] as? String, let workspaceID = screen["workspace_id"] as? String {
                workspaceOfScreen[id] = workspaceID
            }
        }
        var screenOfPane: [String: String] = [:]
        for pane in panesRaw {
            if let id = pane["id"] as? String, let screenID = pane["screen_id"] as? String {
                screenOfPane[id] = screenID
            }
        }
        var paneOfTab: [String: String] = [:]
        var nameOfTab: [String: String] = [:]
        var indexOfTab: [String: Int] = [:]
        var focusedOfTab: [String: Bool] = [:]
        for tab in tabsRaw {
            guard let id = tab["id"] as? String else { continue }
            if let paneID = tab["pane_id"] as? String {
                paneOfTab[id] = paneID
            }
            if let name = (tab["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                nameOfTab[id] = name
            }
            indexOfTab[id] = integer(tab["index"])
            focusedOfTab[id] = tab["focused"] as? Bool
        }
        var agentByTerminal: [String: SurfaceAgentBadge] = [:]
        for agent in agentsRaw {
            guard let terminalID = agent["terminal_id"] as? String, let state = agent["state"] as? String else { continue }
            agentByTerminal[terminalID] = SurfaceAgentBadge(state: state, source: agent["source"] as? String)
        }

        let workspaces = Self.workspaces(fromSnapshot: snapshot)
        var workspaceByID: [String: SurfaceRemoteWorkspace] = [:]
        for workspace in workspaces { workspaceByID[workspace.id] = workspace }

        var resources: [SurfaceResource] = []
        for raw in terminalsRaw {
            guard var terminal = terminal(fromSnapshotEntry: raw, machine: machine, agents: agentByTerminal) else { continue }
            var tabIDs = uniquePreservingOrder((raw["tab_ids"] as? [String]) ?? [])
            if tabIDs.isEmpty, let single = raw["tab_id"] as? String, !single.isEmpty {
                tabIDs = [single]
            }
            // cmux-tui keeps a record of a terminal whose process exited after its tab is
            // gone; nothing can open or close it any more (its selector no longer resolves),
            // so it is not a surface. An exited terminal that still has a tab stays listed —
            // that one can be closed.
            if terminal.lifecycle == .exited, tabIDs.isEmpty { continue }
            // A user-named view labels the terminal everywhere it shows; the PTY title
            // is the fallback (first named tab in the daemon's canonical order).
            if let name = tabIDs.compactMap({ nameOfTab[$0] }).first {
                terminal.title = name
            }
            terminal.remoteViews = tabIDs.compactMap { tabID in
                guard let paneID = paneOfTab[tabID],
                      let screenID = screenOfPane[paneID],
                      let workspaceID = workspaceOfScreen[screenID],
                      let workspace = workspaceByID[workspaceID] else { return nil }
                return SurfaceRemoteView(
                    tabID: tabID,
                    workspace: workspace,
                    screenID: screenID,
                    paneID: paneID,
                    name: nameOfTab[tabID],
                    index: indexOfTab[tabID],
                    focused: focusedOfTab[tabID]
                )
            }
            terminal.remoteWorkspace = terminal.remoteViews?.first?.workspace
            resources.append(terminal)
        }
        // Daemon browsers are workspace tab content just like terminals
        // (`browsers[{id,tab_id,url,title,status}]`) — a workspace holds more than
        // terminals, and the tree shows a browser inside the workspace that views it.
        for raw in (snapshot["browsers"] as? [[String: Any]]) ?? [] {
            guard let id = raw["id"] as? String, !id.isEmpty else { continue }
            let urlString = (raw["url"] as? String) ?? ""
            let title = (raw["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? urlString
            var views: [SurfaceRemoteView] = []
            if let tabID = raw["tab_id"] as? String,
               let paneID = paneOfTab[tabID],
               let screenID = screenOfPane[paneID],
               let workspaceID = workspaceOfScreen[screenID],
               let workspace = workspaceByID[workspaceID] {
                views = [SurfaceRemoteView(
                    tabID: tabID,
                    workspace: workspace,
                    screenID: screenID,
                    paneID: paneID,
                    name: nameOfTab[tabID],
                    index: indexOfTab[tabID],
                    focused: focusedOfTab[tabID]
                )]
            }
            var browser = SurfaceResource(
                id: SurfaceResourceID(machine: machine, kind: .browser, key: id),
                title: title,
                detail: urlString.isEmpty ? nil : urlString,
                lifecycle: (raw["status"] as? String) == "failed" ? .exited : .running,
                agent: nil,
                remoteWorkspace: views.first?.workspace,
                port: localhostPort(fromURL: urlString),
                url: urlString.isEmpty ? nil : urlString
            )
            browser.remoteViews = views
            resources.append(browser)
        }
        // A display tab (`content_kind: "display"`, `content_id: "display:1"`) is a pointer
        // to the machine's screen: the same display resource the pool lists, with one view
        // per workspace tab that holds it — so a workspace remembers its desktop the way
        // it remembers its terminals and browsers.
        var displayViews: [String: [SurfaceRemoteView]] = [:]
        var displayOrder: [String] = []
        for tab in tabsRaw {
            guard (tab["content_kind"] as? String) == "display",
                  let contentID = tab["content_id"] as? String, !contentID.isEmpty,
                  let tabID = tab["id"] as? String,
                  let paneID = paneOfTab[tabID],
                  let screenID = screenOfPane[paneID],
                  let workspaceID = workspaceOfScreen[screenID],
                  let workspace = workspaceByID[workspaceID] else { continue }
            if displayViews[contentID] == nil { displayOrder.append(contentID) }
            displayViews[contentID, default: []].append(SurfaceRemoteView(
                tabID: tabID,
                workspace: workspace,
                screenID: screenID,
                paneID: paneID,
                name: nameOfTab[tabID],
                index: indexOfTab[tabID],
                focused: focusedOfTab[tabID]
            ))
        }
        for contentID in displayOrder {
            var display = Self.display(machine: machine, key: contentID)
            display.remoteViews = displayViews[contentID]
            display.remoteWorkspace = displayViews[contentID]?.first?.workspace
            resources.append(display)
        }
        // Workspace order first; zero-view resources (the pool) trail. Every
        // tie has an explicit key. Returning false for equal workspace indexes
        // would make sorting depend on dictionary/JSON arrival order.
        return resources.sorted(by: resourceComesBefore)
    }

    /// The machine-local port a daemon browser's URL points at, when it does —
    /// `http://localhost:3000/...` and equivalents. A remote browser projects through the
    /// machine's port preview, so only localhost URLs are projectable today.
    static func localhostPort(fromURL urlString: String) -> Int? {
        guard let url = URL(string: urlString), let host = url.host?.lowercased() else { return nil }
        guard ["localhost", "127.0.0.1", "::1", "[::1]", "0.0.0.0"].contains(host) else { return nil }
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }

    /// The tab each terminal currently sits in (`terminals[].tab_ids`/`tab_id`), so an
    /// exited terminal can be closed through its tab when its own selector is gone.
    static func tabByTerminal(fromSnapshot snapshot: [String: Any]) -> [String: String] {
        var result: [String: String] = [:]
        for raw in (snapshot["terminals"] as? [[String: Any]]) ?? [] {
            guard let id = raw["id"] as? String, !id.isEmpty else { continue }
            let tabIDs = ((raw["tab_ids"] as? [String]) ?? []) + [(raw["tab_id"] as? String) ?? ""]
            if let tab = tabIDs.first(where: { !$0.isEmpty }) { result[id] = tab }
        }
        // A display pointer has no process to end: closing it means closing its tab.
        for tab in (snapshot["tabs"] as? [[String: Any]]) ?? [] {
            guard (tab["content_kind"] as? String) == "display",
                  let contentID = tab["content_id"] as? String, !contentID.isEmpty,
                  let tabID = tab["id"] as? String, !tabID.isEmpty, result[contentID] == nil else { continue }
            result[contentID] = tabID
        }
        return result
    }

    /// User labels for tabs in the snapshot. An absent entry means the tab has no
    /// user label (or only whitespace), which lets rename compensation restore the
    /// daemon's unnamed state with an empty value.
    static func tabNames(fromSnapshot snapshot: [String: Any]) -> [String: String] {
        var result: [String: String] = [:]
        for tab in (snapshot["tabs"] as? [[String: Any]]) ?? [] {
            guard let id = tab["id"] as? String, !id.isEmpty,
                  let name = tab["name"] as? String else { continue }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { result[id] = trimmed }
        }
        return result
    }

    /// The workspace and first terminal a `workspace create` mutation made
    /// (`{value: {workspace_id, terminal_id, …}}`).
    static func createdWorkspaceTerminal(fromResult result: [String: Any]) -> (workspaceID: String, terminalID: String?)? {
        let path = (result["value"] as? [String: Any]) ?? result
        guard let workspaceID = ((path["workspace_id"] as? String) ?? (path["id"] as? String)), !workspaceID.isEmpty else { return nil }
        return (workspaceID, (path["terminal_id"] as? String).flatMap { $0.isEmpty ? nil : $0 })
    }

    /// The daemon's workspaces, in its order — including empty ones, which have no
    /// terminal to derive them from.
    static func workspaces(fromSnapshot snapshot: [String: Any]) -> [SurfaceRemoteWorkspace] {
        let workspacesRaw = (snapshot["workspaces"] as? [[String: Any]]) ?? []
        return workspacesRaw.enumerated().compactMap { index, raw in
            guard let id = raw["id"] as? String, !id.isEmpty else { return nil }
            let name = (raw["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id
            return SurfaceRemoteWorkspace(id: id, name: name, index: index, focused: (raw["focused"] as? Bool) ?? false)
        }
    }

    static func terminal(
        fromSnapshotEntry raw: [String: Any],
        machine: SurfaceMachineID,
        agents: [String: SurfaceAgentBadge] = [:]
    ) -> SurfaceResource? {
        guard let id = raw["id"] as? String, !id.isEmpty else { return nil }
        let lifecycle = SurfaceLifecycle(rawValue: (raw["lifecycle"] as? String) ?? "")
            ?? (((raw["running"] as? Bool) ?? false) ? .running : .exited)
        let title = (raw["title"] as? String) ?? ""
        let cwd = (raw["cwd"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return SurfaceResource(
            id: SurfaceResourceID(machine: machine, kind: .terminal, key: id),
            title: title,
            detail: cwd,
            lifecycle: lifecycle,
            agent: agents[id],
            remoteWorkspace: nil,
            port: nil,
            url: nil
        )
    }

    struct CreatedTerminalPath: Equatable, Sendable {
        let terminalID: String
        let workspaceID: String?
        let screenID: String?
        let paneID: String?
        let tabID: String?
    }

    /// The exact path a `workspace <ws> run` / `tab create terminal` mutation
    /// created. The committed result is a read-your-write placement receipt, so
    /// callers do not need to guess a tab while the next snapshot is in flight.
    static func createdTerminal(fromRunResult result: [String: Any]) -> CreatedTerminalPath? {
        let path = (result["value"] as? [String: Any]) ?? result
        guard let terminalID = path["terminal_id"] as? String, !terminalID.isEmpty else { return nil }
        func optionalID(_ key: String) -> String? {
            (path[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        return CreatedTerminalPath(
            terminalID: terminalID,
            workspaceID: optionalID("workspace_id"),
            screenID: optionalID("screen_id"),
            paneID: optionalID("pane_id"),
            tabID: optionalID("tab_id")
        )
    }

    /// The workspace a `workspace create` mutation created.
    static func createdWorkspace(fromResult result: [String: Any]) -> String? {
        let path = (result["value"] as? [String: Any]) ?? result
        let id = (path["workspace_id"] as? String) ?? (path["id"] as? String)
        return id.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// `remote connect --headless --json` prints `{"event":"connection-snapshot","local_socket":…}`
    /// lines; the first one carries the mux socket path.
    static func localSocket(fromLinkLine line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (object["event"] as? String) == "connection-snapshot",
              let socket = object["local_socket"] as? String, !socket.isEmpty else {
            return nil
        }
        return socket
    }

    /// Listening TCP ports from `ss -ltn` / `netstat -ltn` output (what `cmux vm ports` runs).
    static func listeningPorts(fromSocketListing text: String) -> [Int] {
        var seen = Set<Int>()
        var ports: [Int] = []
        for line in text.split(separator: "\n") {
            let columns = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard columns.count >= 4 else { continue }
            // `ss`: State Recv-Q Send-Q Local:Port …; `netstat`: Proto Recv-Q Send-Q Local:Port …
            for column in columns.prefix(5) {
                guard let colon = column.lastIndex(of: ":"), let port = Int(column[column.index(after: colon)...]),
                      (1...65535).contains(port), seen.insert(port).inserted else { continue }
                ports.append(port)
                break
            }
        }
        return ports.sorted()
    }

    /// Ports the tree hides: the daemon and desktop transports the machine itself owns.
    static let internalPorts: Set<Int> = [1337, 5901, 6901, 8080]

    static let desktopPort = 6901

    /// Fallback for callers that only hold an image id. Prefer
    /// ``VMSummary/resolvedKind``, which honors the backend's explicit `kind`.
    /// Only VNC markers count: see ``VMMachineKind/inferred(fromImage:)``.
    static func machineHasDesktop(image: String) -> Bool {
        VMMachineKind.inferred(fromImage: image).hasDesktop
    }

    /// The VNC display of a desktop machine (`display:1`; the key is the daemon's content id
    /// once a workspace points at it).
    static func display(machine: SurfaceMachineID, key: String = "display:1") -> SurfaceResource {
        SurfaceResource(
            id: SurfaceResourceID(machine: machine, kind: .display, key: key),
            title: "Desktop",
            detail: "noVNC",
            lifecycle: .running,
            agent: nil,
            remoteWorkspace: nil,
            port: desktopPort,
            url: nil
        )
    }

    /// The machine's display list after a snapshot: a display the daemon's workspaces point
    /// at (carrying its views) replaces the bare pool entry of the same id; every other
    /// resource passes through. Pure, so the provider's refresh stays a straight line.
    static func mergingDisplays(pool: [SurfaceResource], parsed: [SurfaceResource]) -> [SurfaceResource] {
        let pointed = Set(parsed.filter { $0.kind == .display }.map(\.id))
        return pool.filter { !($0.kind == .display && pointed.contains($0.id)) } + parsed
    }

    /// A forwarded port, shown as a browser resource. `directURL`, when
    /// given, is where opening it actually navigates — the machine's private
    /// address over the WireGuard tunnel, never a provider port-forwarding
    /// proxy (Freestyle's public platform has none for arbitrary ports). nil
    /// only for a machine with no private-network address yet, which falls
    /// back to the legacy provider-minted-endpoint path.
    static func portBrowser(machine: SurfaceMachineID, port: Int, directURL: String? = nil) -> SurfaceResource {
        SurfaceResource(
            id: SurfaceResourceID(machine: machine, kind: .browser, key: "port:\(port)"),
            title: ":\(port)",
            detail: nil,
            lifecycle: .running,
            agent: nil,
            remoteWorkspace: nil,
            port: port,
            url: directURL
        )
    }

    /// The noVNC page recipe `cmux vm desktop` uses: auto-connect, follow the pane's size,
    /// reconnect after a sleep.
    static func desktopURL(openURL: String) -> String {
        openURL + "&autoconnect=1&resize=remote&reconnect=1&reconnect_delay=2000"
    }

    // MARK: - Lossless state helpers

    private static func nonEmptyString(_ raw: Any?) -> String? {
        guard let value = raw as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func integer(_ raw: Any?) -> Int? {
        CloudWireNumber.signed(raw)
    }

    private static func canonicalJSONData(_ object: Any) -> Data? {
        guard JSONSerialization.isValidJSONObject(object) else { return nil }
        return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private static func resourceComesBefore(_ lhs: SurfaceResource, _ rhs: SurfaceResource) -> Bool {
        let leftView = lhs.remoteViews?.first
        let rightView = rhs.remoteViews?.first
        let leftWorkspace = leftView?.workspace ?? lhs.remoteWorkspace
        let rightWorkspace = rightView?.workspace ?? rhs.remoteWorkspace
        let leftWorkspaceIndex = leftWorkspace?.index ?? Int.max
        let rightWorkspaceIndex = rightWorkspace?.index ?? Int.max
        if leftWorkspaceIndex != rightWorkspaceIndex { return leftWorkspaceIndex < rightWorkspaceIndex }
        let leftWorkspaceID = leftWorkspace?.id ?? "~"
        let rightWorkspaceID = rightWorkspace?.id ?? "~"
        if leftWorkspaceID != rightWorkspaceID { return leftWorkspaceID < rightWorkspaceID }
        let leftTabIndex = leftView?.index ?? Int.max
        let rightTabIndex = rightView?.index ?? Int.max
        if leftTabIndex != rightTabIndex { return leftTabIndex < rightTabIndex }
        let leftTabID = leftView?.tabID ?? "~"
        let rightTabID = rightView?.tabID ?? "~"
        if leftTabID != rightTabID { return leftTabID < rightTabID }
        if lhs.kind.rawValue != rhs.kind.rawValue { return lhs.kind.rawValue < rhs.kind.rawValue }
        return lhs.id.key < rhs.id.key
    }

    private static func entityValues(kind: String, objects: [[String: Any]]) -> [CloudVMEntity] {
        objects.compactMap { object in
            guard let payload = canonicalJSONData(object) else { return nil }
            return CloudVMEntity(kind: kind, id: nonEmptyString(object["id"]), payload: payload)
        }
    }

    private enum DeltaStorage {
        case single(String)
        case collection(String)
    }

    private static func deltaStorage(for resource: String) -> DeltaStorage? {
        switch resource {
        case "machine": return .single("machine")
        case "session": return .single("session")
        case "workspace": return .collection("workspaces")
        case "screen": return .collection("screens")
        case "pane": return .collection("panes")
        case "tab": return .collection("tabs")
        case "terminal": return .collection("terminals")
        case "browser": return .collection("browsers")
        case "client": return .collection("clients")
        case "notification": return .collection("notifications")
        case "agent": return .collection("agents")
        case "pairing_request": return .collection("pairing_requests")
        case "frontend_projection": return .collection("frontend_projections")
        case "sidebar_view": return .collection("sidebar_views")
        default: return nil
        }
    }
}
