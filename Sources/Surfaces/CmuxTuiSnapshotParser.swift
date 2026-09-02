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
/// `terminals[{id,tab_id,title,cwd?,lifecycle}]`,
/// `agents[{id?,terminal_id,state,source}]`.
/// A tab's `name` is the user-set label (`tab.rename`, persisted in the daemon's
/// registry); the terminal's `title` is PTY-derived. A named view wins over the title.
struct CloudVMStateDeltaImpact: Hashable, Sendable {
    /// Resource identities whose derived rows can be rebuilt without touching unrelated rows.
    var resourceIDs: Set<SurfaceResourceID> = []
    /// Relationship changes can move many resources at once. These use the authoritative full
    /// rebuild path instead of risking a partial placement update.
    var requiresFullResourceRebuild = false
}

struct CloudVMStateDeltaApplication: Sendable {
    let state: CloudVMState
    let impact: CloudVMStateDeltaImpact
}

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
    /// A missing or explicit-null cursor is a legacy snapshot-only state. A
    /// present cursor must be valid, because accepting a malformed ordering token
    /// would make later deltas target the wrong graph.
    static func state(fromSnapshot snapshot: [String: Any], machine: SurfaceMachineID) -> CloudVMState? {
        let cursor: CloudVMCursor?
        if let rawCursor = snapshot["cursor"], !(rawCursor is NSNull) {
            guard let parsed = CloudVMCursor(snapshot: snapshot) else { return nil }
            cursor = parsed
        } else {
            cursor = nil
        }
        guard let rawSnapshot = canonicalJSONData(snapshot),
              identityCollectionsAreUnique(in: snapshot),
              snapshotRelationshipsAreConsistent(in: snapshot)
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

    /// A synchronizable remote graph is keyed by daemon IDs. Silently choosing
    /// the first or last malformed row would make a rename or projection target
    /// depend on wire order, or make an entity disappear while the snapshot is
    /// still marked current. Reject the whole document at this boundary so the
    /// provider takes its bounded full-snapshot recovery path instead.
    private static func identityCollectionsAreUnique(in snapshot: [String: Any]) -> Bool {
        var agentTerminalIDs = Set<String>()
        for key in ["workspaces", "screens", "panes", "tabs", "terminals", "browsers", "agents"] {
            guard let raw = snapshot[key] else { continue }
            guard let rows = raw as? [[String: Any]] else { return false }
            var ids = Set<String>()
            for row in rows {
                // Agent ids were added after the first public snapshot schema. Their stable
                // relationship key is terminal_id, so an older daemon may omit id while the
                // rest of the graph remains fully usable. Every other known row still needs a
                // non-empty unique id because it is the identity used by deltas and projections.
                if key == "agents" {
                    if let rawID = row["id"], !(rawID is NSNull) {
                        guard let id = nonEmptyString(rawID), ids.insert(id).inserted else { return false }
                    }
                } else {
                    guard let id = nonEmptyString(row["id"]), ids.insert(id).inserted else {
                        return false
                    }
                }
                switch key {
                case "screens":
                    guard nonEmptyString(row["workspace_id"]) != nil else { return false }
                case "panes":
                    guard nonEmptyString(row["screen_id"]) != nil else { return false }
                case "tabs":
                    guard nonEmptyString(row["pane_id"]) != nil,
                          nonEmptyString(row["content_kind"]) != nil,
                          nonEmptyString(row["content_id"]) != nil
                    else { return false }
                case "terminals":
                    if let rawTabIDs = row["tab_ids"] {
                        guard let tabIDs = rawTabIDs as? [String],
                              tabIDs.allSatisfy({ nonEmptyString($0) != nil })
                        else { return false }
                    }
                    if let rawTabID = row["tab_id"], !(rawTabID is NSNull) {
                        guard nonEmptyString(rawTabID) != nil else { return false }
                    }
                case "browsers":
                    guard nonEmptyString(row["tab_id"]) != nil else { return false }
                case "agents":
                    guard let terminalID = nonEmptyString(row["terminal_id"]),
                          nonEmptyString(row["state"]) != nil,
                          agentTerminalIDs.insert(terminalID).inserted
                    else { return false }
                default:
                    break
                }
            }
        }
        return true
    }

    /// Verifies the foreign-key edges that determine a remote placement. A
    /// terminal id alone is not enough: the tab must explicitly identify that
    /// same terminal. Otherwise a stale or malformed tab reference can make a
    /// rename or open operation target another terminal. Missing terminal tabs
    /// remain allowed for exited or detached daemon records, which preserves
    /// the documented pool representation.
    private static func snapshotRelationshipsAreConsistent(in snapshot: [String: Any]) -> Bool {
        let workspaces = (snapshot["workspaces"] as? [[String: Any]]) ?? []
        let screens = (snapshot["screens"] as? [[String: Any]]) ?? []
        let panes = (snapshot["panes"] as? [[String: Any]]) ?? []
        let tabs = (snapshot["tabs"] as? [[String: Any]]) ?? []
        let terminals = (snapshot["terminals"] as? [[String: Any]]) ?? []
        let browsers = (snapshot["browsers"] as? [[String: Any]]) ?? []

        let workspaceIDs = Set(workspaces.compactMap { nonEmptyString($0["id"]) })
        let screenIDs = Set(screens.compactMap { nonEmptyString($0["id"]) })
        let paneIDs = Set(panes.compactMap { nonEmptyString($0["id"]) })
        var tabByID: [String: [String: Any]] = [:]
        for tab in tabs {
            guard let tabID = nonEmptyString(tab["id"]) else { return false }
            tabByID[tabID] = tab
            guard let paneID = nonEmptyString(tab["pane_id"]), paneIDs.contains(paneID) else { return false }
        }
        for screen in screens {
            guard let workspaceID = nonEmptyString(screen["workspace_id"]), workspaceIDs.contains(workspaceID) else {
                return false
            }
        }
        for pane in panes {
            guard let screenID = nonEmptyString(pane["screen_id"]), screenIDs.contains(screenID) else { return false }
        }

        func referencedTabIDs(in terminal: [String: Any]) -> [String] {
            var ids = (terminal["tab_ids"] as? [String]) ?? []
            if let tabID = nonEmptyString(terminal["tab_id"]), !ids.contains(tabID) {
                ids.append(tabID)
            }
            return ids
        }

        for terminal in terminals {
            guard let terminalID = nonEmptyString(terminal["id"]) else { return false }
            for tabID in referencedTabIDs(in: terminal) {
                // A missing tab is a valid detached/exited state. An existing
                // tab with a different content identity is never safe to use.
                guard let tab = tabByID[tabID] else { continue }
                guard nonEmptyString(tab["content_kind"]) == "terminal",
                      nonEmptyString(tab["content_id"]) == terminalID
                else { return false }
            }
        }

        for browser in browsers {
            guard let browserID = nonEmptyString(browser["id"]),
                  let tabID = nonEmptyString(browser["tab_id"])
            else { return false }
            guard let tab = tabByID[tabID] else { continue }
            guard nonEmptyString(tab["content_kind"]) == "browser",
                  nonEmptyString(tab["content_id"]) == browserID
            else { return false }
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

    /// Re-derives only selected resource rows from the exact state bytes. Relationship maps
    /// are built once because a tab rename can join through pane and screen, but unrelated
    /// terminals and browsers are never allocated, sorted, or compared. The provider uses
    /// this for row-local deltas and reserves the complete path for topology changes.
    static func resources(
        from state: CloudVMState,
        matching resourceIDs: Set<SurfaceResourceID>
    ) -> [SurfaceResource] {
        guard !resourceIDs.isEmpty else { return [] }

        // Row-local deltas use the typed graph directly. The graph was accepted
        // at a full snapshot boundary, and applyingTypedDelta checked the changed
        // relationship neighborhood, so decoding rawSnapshot here would repeat
        // the full-document validation on every title or agent update.
        let workspaces = Dictionary(uniqueKeysWithValues: state.workspaces.map { ($0.id, $0) })
        let screens = Dictionary(uniqueKeysWithValues: state.screens.map { ($0.id, $0) })
        let panes = Dictionary(uniqueKeysWithValues: state.panes.map { ($0.id, $0) })
        let tabs = Dictionary(uniqueKeysWithValues: state.tabs.map { ($0.id, $0) })
        let agents = Dictionary(uniqueKeysWithValues: state.agents.map { ($0.terminalID, $0) })

        func workspace(for tab: CloudVMTabState) -> SurfaceRemoteWorkspace? {
            guard let pane = panes[tab.paneID],
                  let screen = screens[pane.screenID],
                  let workspace = workspaces[screen.workspaceID]
            else { return nil }
            return SurfaceRemoteWorkspace(
                id: workspace.id,
                name: workspace.name,
                index: workspace.index,
                focused: workspace.focused
            )
        }

        func view(for tab: CloudVMTabState) -> SurfaceRemoteView? {
            guard let workspace = workspace(for: tab) else { return nil }
            return SurfaceRemoteView(
                tabID: tab.id,
                workspace: workspace,
                screenID: panes[tab.paneID].flatMap { screens[$0.screenID]?.id },
                paneID: tab.paneID,
                name: tab.name,
                index: tab.index,
                focused: tab.focused
            )
        }

        var resources: [SurfaceResource] = []
        for resourceID in resourceIDs where resourceID.machine == state.machine {
            switch resourceID.kind {
            case .terminal:
                guard let terminal = state.terminals.first(where: { $0.id == resourceID.key }) else { continue }
                let tabIDs = uniquePreservingOrder(terminal.tabIDs)
                if terminal.lifecycle == SurfaceLifecycle.exited.rawValue, tabIDs.isEmpty { continue }
                var resource = SurfaceResource(
                    id: resourceID,
                    title: terminal.title,
                    detail: terminal.cwd,
                    lifecycle: SurfaceLifecycle(rawValue: terminal.lifecycle)
                        ?? (terminal.running == true ? .running : .exited),
                    agent: agents[terminal.id].map {
                        SurfaceAgentBadge(state: $0.state, source: $0.source)
                    },
                    remoteWorkspace: nil,
                    port: nil,
                    url: nil
                )
                resource.remoteViews = tabIDs.compactMap { tabID in
                    guard let tab = tabs[tabID],
                          tab.contentKind == "terminal",
                          tab.contentID == terminal.id
                    else { return nil }
                    return view(for: tab)
                }
                resource.remoteWorkspace = resource.remoteViews?.first?.workspace
                resources.append(resource)
            case .browser:
                guard let browser = state.browsers.first(where: { $0.id == resourceID.key }) else { continue }
                let remoteView: SurfaceRemoteView? = tabs[browser.tabID].flatMap { tab in
                    guard tab.contentKind == "browser", tab.contentID == browser.id else { return nil }
                    return view(for: tab)
                }
                var resource = SurfaceResource(
                    id: resourceID,
                    title: browser.title.isEmpty ? browser.url : browser.title,
                    detail: browser.url.isEmpty ? nil : browser.url,
                    lifecycle: browser.status == "failed" ? .exited : .running,
                    agent: nil,
                    remoteWorkspace: remoteView?.workspace,
                    port: localhostPort(fromURL: browser.url),
                    url: browser.url.isEmpty ? nil : browser.url
                )
                resource.remoteViews = remoteView.map { [$0] } ?? []
                resources.append(resource)
            case .display:
                var views: [SurfaceRemoteView] = []
                for tab in state.tabs where tab.contentKind == "display" && tab.contentID == resourceID.key {
                    if let remoteView = view(for: tab) { views.append(remoteView) }
                }
                guard !views.isEmpty else { continue }
                var resource = display(machine: state.machine, key: resourceID.key)
                resource.remoteViews = views
                resource.remoteWorkspace = views.first?.workspace
                resources.append(resource)
            default:
                continue
            }
        }
        return resources.sorted(by: resourceComesBefore)
    }

    /// Applies one contiguous `session.delta` batch to the complete raw graph,
    /// then rebuilds the typed indexes from that one result. The impact tells the
    /// provider whether it can update selected resource rows or must rebuild all
    /// relationships. Upserts replace an entity in place, deletes remove it, and
    /// unknown resource kinds refuse the batch so the caller can fetch a snapshot.
    static func applying(
        deltaPayload: Data,
        cursor: CloudVMCursor,
        to state: CloudVMState
    ) -> CloudVMState? {
        applyingWithImpact(deltaPayload: deltaPayload, cursor: cursor, to: state)?.state
    }

    static func applyingWithImpact(
        deltaPayload: Data,
        cursor: CloudVMCursor,
        to state: CloudVMState
    ) -> CloudVMStateDeltaApplication? {
        guard let currentCursor = state.cursor,
              var snapshot = state.snapshotObject(),
              let delta = try? JSONSerialization.jsonObject(with: deltaPayload) as? [String: Any],
              let changes = delta["changes"] as? [[String: Any]],
              currentCursor.generation == cursor.generation,
              currentCursor.revision < UInt64.max,
              cursor.revision == currentCursor.revision + 1,
              deltaEnvelopeMatches(delta, cursor: cursor, previousRevision: currentCursor.revision),
              deltaSequencesAreValid(changes)
        else { return nil }

        for change in changes {
            guard let kind = nonEmptyString(change["kind"]),
                  let resource = nonEmptyString(change["resource"]),
                  let storage = deltaStorage(for: resource)
            else { return nil }

            // Agent ids were not present in the first public snapshot schema. Use the
            // terminal relationship as the compatibility identity when an old daemon omits
            // `id`; all other resources still require their explicit daemon id.
            let value = change["value"] as? [String: Any]
            let explicitID = nonEmptyString(change["id"])
            let valueTerminalID = value.flatMap { nonEmptyString($0["terminal_id"]) }
            if resource == "agent",
               let explicitID,
               let valueID = value.flatMap({ nonEmptyString($0["id"]) }),
               valueID != explicitID {
                return nil
            }
            if resource == "agent",
               let changeTerminalID = nonEmptyString(change["terminal_id"]),
               let valueTerminalID,
               changeTerminalID != valueTerminalID {
                return nil
            }
            let compatibilityID: String? = if resource == "agent" {
                explicitID
                    ?? nonEmptyString(change["terminal_id"])
                    ?? value.flatMap { nonEmptyString($0["id"]) ?? nonEmptyString($0["terminal_id"]) }
            } else {
                explicitID
            }
            guard let id = compatibilityID else { return nil }

            switch kind {
            case "upsert":
                guard let value,
                      resource == "agent" || nonEmptyString(value["id"]) == id
                else { return nil }
                switch storage {
                case .single(let key):
                    snapshot[key] = value
                case .collection(let key):
                    var values = (snapshot[key] as? [[String: Any]]) ?? []
                    let index: Int?
                    if resource == "agent" {
                        // The terminal id is the stable key for legacy rows. An explicit
                        // id with no existing id match and a changed terminal is ambiguous:
                        // it may be a new agent, or an id-less legacy agent being reassigned.
                        // Appending in that case leaves a stale badge, so force a snapshot.
                        guard let valueTerminalID else { return nil }
                        let idIndex = explicitID.flatMap { id in
                            values.firstIndex { nonEmptyString($0["id"]) == id }
                        }
                        let terminalIndex = values.firstIndex {
                            nonEmptyString($0["terminal_id"]) == valueTerminalID
                        }
                        if let idIndex {
                            if let terminalIndex, terminalIndex != idIndex { return nil }
                            index = idIndex
                        } else if let terminalIndex {
                            // A legacy row can safely acquire an explicit id only when
                            // the relationship still points at that exact terminal.
                            if explicitID != nil,
                               nonEmptyString(values[terminalIndex]["id"]) != nil {
                                return nil
                            }
                            index = terminalIndex
                        } else {
                            // Without a relationship match, an explicit id cannot prove
                            // that any existing id-less row is unrelated to this upsert.
                            let hasUnidentifiedLegacyRow = values.contains {
                                nonEmptyString($0["id"]) == nil
                            }
                            guard explicitID == nil || !hasUnidentifiedLegacyRow else { return nil }
                            index = nil
                        }
                    } else {
                        index = values.firstIndex(where: { nonEmptyString($0["id"]) == id })
                    }
                    if let index {
                        var storedValue = value
                        // Preserve a known explicit id when an older daemon omits it
                        // from a relationship-keyed update. This keeps future deltas
                        // addressable without inventing a new identity.
                        if resource == "agent",
                           explicitID == nil,
                           let existingID = nonEmptyString(values[index]["id"]),
                           nonEmptyString(storedValue["id"]) == nil {
                            storedValue["id"] = existingID
                        }
                        values[index] = storedValue
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
                    if resource == "agent" {
                        let terminalID = nonEmptyString(change["terminal_id"]) ?? valueTerminalID
                        if let explicitID {
                            if let index = values.firstIndex(where: { nonEmptyString($0["id"]) == explicitID }) {
                                if let terminalID,
                                   nonEmptyString(values[index]["terminal_id"]) != terminalID {
                                    return nil
                                }
                                values.remove(at: index)
                            } else if let terminalID,
                                      let index = values.firstIndex(where: {
                                          nonEmptyString($0["id"]) == nil
                                              && nonEmptyString($0["terminal_id"]) == terminalID
                                      }) {
                                // A legacy id-less row is deletable only when its
                                // relationship supplies the missing identity.
                                values.remove(at: index)
                            } else {
                                return nil
                            }
                        } else {
                            guard let terminalID,
                                  let index = values.firstIndex(where: {
                                      nonEmptyString($0["terminal_id"]) == terminalID
                                  })
                            else { return nil }
                            values.remove(at: index)
                        }
                    } else {
                        values.removeAll { nonEmptyString($0["id"]) == id }
                    }
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
        guard let rawSnapshot = canonicalJSONData(snapshot),
              let next = Self.applyingTypedDelta(
                  changes,
                  to: state,
                  cursor: cursor,
                  snapshot: snapshot,
                  rawSnapshot: rawSnapshot
              )
        else { return nil }
        return CloudVMStateDeltaApplication(
            state: next,
            impact: deltaImpact(changes, previous: state, next: next)
        )
    }

    /// Applies the typed part of a delta without reparsing the complete remote
    /// document. The raw document was already patched above and remains the
    /// authority. Typed rows are changed only for entities named by this batch;
    /// relationship checks then cover those rows and their immediate edges.
    private static func applyingTypedDelta(
        _ changes: [[String: Any]],
        to state: CloudVMState,
        cursor: CloudVMCursor,
        snapshot: [String: Any],
        rawSnapshot: Data
    ) -> CloudVMState? {
        var next = state
        next.cursor = cursor
        next.rawSnapshot = rawSnapshot
        var changedPaneIDs = Set<String>()
        var opaqueResources = Set<String>()

        for change in changes {
            guard let resource = nonEmptyString(change["resource"]),
                  let operation = nonEmptyString(change["kind"]),
                  let id = deltaIdentity(change, resource: resource)
            else { return nil }
            let value = change["value"] as? [String: Any]

            switch (resource, operation) {
            case ("workspace", "upsert"):
                let existingIndex = next.workspaces.firstIndex(where: { $0.id == id })
                let fallbackIndex = existingIndex.map { next.workspaces[$0].index } ?? next.workspaces.count
                guard let value,
                      let decoded = workspaceState(from: value, fallbackIndex: fallbackIndex)
                else { return nil }
                if let existingIndex {
                    next.workspaces[existingIndex] = decoded
                } else {
                    next.workspaces.append(decoded)
                }
            case ("screen", "upsert"):
                let existingIndex = next.screens.firstIndex(where: { $0.id == id })
                let fallbackIndex = existingIndex.map { next.screens[$0].index } ?? next.screens.count
                guard let value,
                      let decoded = screenState(from: value, fallbackIndex: fallbackIndex)
                else { return nil }
                if let existingIndex {
                    next.screens[existingIndex] = decoded
                } else {
                    next.screens.append(decoded)
                }
            case ("pane", "upsert"):
                guard let value,
                      let decoded = paneState(
                          from: value,
                          fallbackTabIDs: next.panes.first(where: { $0.id == id })?.tabIDs ?? []
                      )
                else { return nil }
                if let index = next.panes.firstIndex(where: { $0.id == id }) {
                    next.panes[index] = decoded
                } else {
                    next.panes.append(decoded)
                }
                changedPaneIDs.insert(id)
            case ("tab", "upsert"):
                let old = next.tabs.first { $0.id == id }
                let fallbackIndex = old?.index ?? next.tabs.count
                guard let value,
                      let decoded = tabState(from: value, fallbackIndex: fallbackIndex)
                else { return nil }
                if let old {
                    if old.paneID != decoded.paneID {
                        changedPaneIDs.insert(old.paneID)
                        changedPaneIDs.insert(decoded.paneID)
                    }
                } else {
                    changedPaneIDs.insert(decoded.paneID)
                }
                if let index = next.tabs.firstIndex(where: { $0.id == id }) {
                    next.tabs[index] = decoded
                } else {
                    next.tabs.append(decoded)
                }
            case ("terminal", "upsert"):
                guard let value,
                      let decoded = terminalState(from: value)
                else { return nil }
                if let index = next.terminals.firstIndex(where: { $0.id == id }) {
                    next.terminals[index] = decoded
                } else {
                    next.terminals.append(decoded)
                }
            case ("browser", "upsert"):
                guard let value,
                      let decoded = browserState(from: value)
                else { return nil }
                if let index = next.browsers.firstIndex(where: { $0.id == id }) {
                    next.browsers[index] = decoded
                } else {
                    next.browsers.append(decoded)
                }
            case ("agent", "upsert"):
                guard let value else { return nil }
                guard applyAgentUpsert(value: value, change: change, to: &next) else { return nil }
            case (_, "upsert") where !["workspace", "screen", "pane", "tab", "terminal", "browser", "agent"].contains(resource):
                opaqueResources.insert(resource)
            case ("workspace", "delete"):
                next.workspaces.removeAll { $0.id == id }
            case ("screen", "delete"):
                next.screens.removeAll { $0.id == id }
            case ("pane", "delete"):
                if let pane = next.panes.first(where: { $0.id == id }) {
                    changedPaneIDs.insert(pane.id)
                }
                next.panes.removeAll { $0.id == id }
            case ("tab", "delete"):
                if let tab = next.tabs.first(where: { $0.id == id }) {
                    changedPaneIDs.insert(tab.paneID)
                }
                next.tabs.removeAll { $0.id == id }
            case ("terminal", "delete"):
                next.terminals.removeAll { $0.id == id }
            case ("browser", "delete"):
                next.browsers.removeAll { $0.id == id }
            case ("agent", "delete"):
                guard applyAgentDelete(change: change, to: &next) else { return nil }
            case (_, "delete") where !["workspace", "screen", "pane", "tab", "terminal", "browser", "agent"].contains(resource):
                opaqueResources.insert(resource)
            default:
                return nil
            }
        }

        // A tab move/create/delete changes the derived pane child list. This is
        // a topology path, so the affected panes are the only rows rescanned.
        for paneID in changedPaneIDs {
            guard let index = next.panes.firstIndex(where: { $0.id == paneID }) else { continue }
            next.panes[index].tabIDs = next.tabs.filter { $0.paneID == paneID }.map(\.id)
        }
        for resource in opaqueResources {
            refreshOpaqueEntities(resource: resource, snapshot: snapshot, state: &next)
        }
        guard deltaRelationshipsAreConsistent(changes, previous: state, next: next) else { return nil }
        return next
    }

    private static func deltaIdentity(_ change: [String: Any], resource: String) -> String? {
        let value = change["value"] as? [String: Any]
        if resource == "agent" {
            return nonEmptyString(change["id"])
                ?? nonEmptyString(change["terminal_id"])
                ?? value.flatMap { nonEmptyString($0["id"]) ?? nonEmptyString($0["terminal_id"]) }
        }
        return nonEmptyString(change["id"])
    }

    private static func workspaceState(from value: [String: Any], fallbackIndex: Int) -> CloudVMWorkspaceState? {
        guard let id = nonEmptyString(value["id"]) else { return nil }
        return CloudVMWorkspaceState(
            id: id,
            name: nonEmptyString(value["name"]) ?? id,
            index: integer(value["index"]) ?? fallbackIndex,
            focused: value["focused"] as? Bool ?? false
        )
    }

    private static func screenState(from value: [String: Any], fallbackIndex: Int) -> CloudVMScreenState? {
        guard let id = nonEmptyString(value["id"]),
              let workspaceID = nonEmptyString(value["workspace_id"])
        else { return nil }
        return CloudVMScreenState(
            id: id,
            workspaceID: workspaceID,
            name: nonEmptyString(value["name"]),
            index: integer(value["index"]) ?? fallbackIndex,
            focused: value["focused"] as? Bool ?? false,
            layout: value["layout"].flatMap(canonicalJSONData)
        )
    }

    private static func paneState(from value: [String: Any], fallbackTabIDs: [String]) -> CloudVMPaneState? {
        guard let id = nonEmptyString(value["id"]),
              let screenID = nonEmptyString(value["screen_id"])
        else { return nil }
        return CloudVMPaneState(
            id: id,
            screenID: screenID,
            name: nonEmptyString(value["name"]),
            focused: value["focused"] as? Bool ?? false,
            zoomed: value["zoomed"] as? Bool ?? false,
            tabIDs: fallbackTabIDs
        )
    }

    private static func tabState(from value: [String: Any], fallbackIndex: Int) -> CloudVMTabState? {
        guard let id = nonEmptyString(value["id"]),
              let paneID = nonEmptyString(value["pane_id"]),
              let contentKind = nonEmptyString(value["content_kind"]),
              let contentID = nonEmptyString(value["content_id"])
        else { return nil }
        return CloudVMTabState(
            id: id,
            paneID: paneID,
            name: nonEmptyString(value["name"]),
            index: integer(value["index"]) ?? fallbackIndex,
            focused: value["focused"] as? Bool ?? false,
            contentKind: contentKind,
            contentID: contentID
        )
    }

    private static func terminalState(from value: [String: Any]) -> CloudVMTerminalState? {
        guard let id = nonEmptyString(value["id"]) else { return nil }
        var tabIDs: [String] = []
        if let rawTabIDs = value["tab_ids"] {
            guard let decodedTabIDs = rawTabIDs as? [String],
                  decodedTabIDs.allSatisfy({ nonEmptyString($0) != nil })
            else { return nil }
            tabIDs = uniquePreservingOrder(decodedTabIDs)
        }
        if let rawTabID = value["tab_id"], !(rawTabID is NSNull) {
            guard let tabID = nonEmptyString(rawTabID) else { return nil }
            if tabIDs.isEmpty { tabIDs = [tabID] }
        }
        return CloudVMTerminalState(
            id: id,
            tabIDs: tabIDs,
            title: (value["title"] as? String) ?? "",
            cwd: nonEmptyString(value["cwd"]),
            lifecycle: (value["lifecycle"] as? String) ?? ((value["running"] as? Bool) == true ? "running" : "exited"),
            cols: integer(value["cols"]),
            rows: integer(value["rows"]),
            running: value["running"] as? Bool
        )
    }

    private static func browserState(from value: [String: Any]) -> CloudVMBrowserState? {
        guard let id = nonEmptyString(value["id"]),
              let tabID = nonEmptyString(value["tab_id"])
        else { return nil }
        return CloudVMBrowserState(
            id: id,
            tabID: tabID,
            url: (value["url"] as? String) ?? "",
            title: (value["title"] as? String) ?? "",
            status: (value["status"] as? String) ?? ""
        )
    }

    private static func agentState(from value: [String: Any]) -> CloudVMAgentState? {
        guard let terminalID = nonEmptyString(value["terminal_id"]),
              let state = nonEmptyString(value["state"])
        else { return nil }
        return CloudVMAgentState(
            id: nonEmptyString(value["id"]),
            terminalID: terminalID,
            state: state,
            source: nonEmptyString(value["source"])
        )
    }

    private static func applyAgentUpsert(
        value: [String: Any],
        change: [String: Any],
        to state: inout CloudVMState
    ) -> Bool {
        guard var decoded = agentState(from: value),
              let terminalID = nonEmptyString(value["terminal_id"])
        else { return false }
        let explicitID = nonEmptyString(change["id"])
        let targetIndex = explicitID.flatMap { id in state.agents.firstIndex { $0.id == id } }
            ?? state.agents.firstIndex { $0.terminalID == terminalID }
        if targetIndex == nil, explicitID != nil,
           state.agents.contains(where: { $0.id == nil }) {
            // An explicit id cannot safely claim an unrelated legacy id-less row.
            return false
        }
        if let targetIndex {
            if explicitID == nil, decoded.id == nil, let existingID = state.agents[targetIndex].id {
                decoded.id = existingID
            }
            state.agents[targetIndex] = decoded
        } else {
            state.agents.append(decoded)
        }
        return true
    }

    private static func applyAgentDelete(change: [String: Any], to state: inout CloudVMState) -> Bool {
        let explicitID = nonEmptyString(change["id"])
        let terminalID = nonEmptyString(change["terminal_id"])
            ?? (change["value"] as? [String: Any]).flatMap { nonEmptyString($0["terminal_id"]) }
        if let explicitID,
           let index = state.agents.firstIndex(where: { $0.id == explicitID }) {
            if let terminalID, state.agents[index].terminalID != terminalID { return false }
            state.agents.remove(at: index)
            return true
        }
        guard let terminalID,
              let index = state.agents.firstIndex(where: { $0.id == nil && $0.terminalID == terminalID })
        else { return false }
        state.agents.remove(at: index)
        return true
    }

    private static func refreshOpaqueEntities(
        resource: String,
        snapshot: [String: Any],
        state: inout CloudVMState
    ) {
        let key = snapshotKey(for: resource)
        let values: [[String: Any]]
        if let object = snapshot[key] as? [String: Any] {
            values = [object]
        } else {
            values = (snapshot[key] as? [[String: Any]]) ?? []
        }
        state.otherEntities.removeAll { $0.kind == key }
        state.otherEntities.append(contentsOf: entityValues(kind: key, objects: values))
        state.otherEntities.sort {
            if $0.kind != $1.kind { return $0.kind < $1.kind }
            let leftID = $0.id ?? ""
            let rightID = $1.id ?? ""
            if leftID != rightID { return leftID < rightID }
            return $0.payload.lexicographicallyPrecedes($1.payload)
        }
    }

    private static func snapshotKey(for resource: String) -> String {
        switch resource {
        case "machine", "machines": return "machine"
        case "session", "sessions": return "session"
        case "workspace", "workspaces": return "workspaces"
        case "screen", "screens": return "screens"
        case "pane", "panes": return "panes"
        case "tab", "tabs": return "tabs"
        case "terminal", "terminals": return "terminals"
        case "browser", "browsers": return "browsers"
        case "client", "clients": return "clients"
        case "notification", "notifications": return "notifications"
        case "agent", "agents": return "agents"
        case "pairing_request", "pairing_requests": return "pairing_requests"
        case "frontend_projection", "frontend_projections": return "frontend_projections"
        case "sidebar_view", "sidebar_views": return "sidebar_views"
        default: return resource
        }
    }

    /// Checks only the foreign-key neighborhood touched by a delta. The prior
    /// state was accepted at a full snapshot boundary, so unrelated rows cannot
    /// become invalid without being named by this batch.
    private static func deltaRelationshipsAreConsistent(
        _ changes: [[String: Any]],
        previous: CloudVMState,
        next: CloudVMState
    ) -> Bool {
        var affectedTerminalIDs = Set<String>()
        var affectedBrowserIDs = Set<String>()
        for change in changes {
            guard let resource = nonEmptyString(change["resource"]),
                  let operation = nonEmptyString(change["kind"]),
                  let id = deltaIdentity(change, resource: resource)
            else { return false }
            switch resource {
            case "workspace":
                if operation == "delete" {
                    guard !next.screens.contains(where: { $0.workspaceID == id }) else { return false }
                } else {
                    guard next.workspaces.contains(where: { $0.id == id }) else { return false }
                }
            case "screen":
                if operation == "delete" {
                    guard !next.panes.contains(where: { $0.screenID == id }) else { return false }
                } else if let screen = next.screens.first(where: { $0.id == id }) {
                    guard next.workspaces.contains(where: { $0.id == screen.workspaceID }) else { return false }
                } else { return false }
            case "pane":
                if operation == "delete" {
                    guard !next.tabs.contains(where: { $0.paneID == id }) else { return false }
                } else if let pane = next.panes.first(where: { $0.id == id }) {
                    guard next.screens.contains(where: { $0.id == pane.screenID }) else { return false }
                } else { return false }
            case "tab":
                let old = previous.tabs.first { $0.id == id }
                let current = next.tabs.first { $0.id == id }
                for tab in [old, current].compactMap({ $0 }) {
                    if let terminalID = tab.contentKind == "terminal" ? tab.contentID : nil {
                        affectedTerminalIDs.insert(terminalID)
                    }
                    if let browserID = tab.contentKind == "browser" ? tab.contentID : nil {
                        affectedBrowserIDs.insert(browserID)
                    }
                }
                if operation != "delete" {
                    guard let tab = current,
                          next.panes.contains(where: { $0.id == tab.paneID })
                    else { return false }
                }
            case "terminal":
                affectedTerminalIDs.insert(id)
            case "browser":
                affectedBrowserIDs.insert(id)
            case "agent":
                let terminalID = (change["value"] as? [String: Any]).flatMap { nonEmptyString($0["terminal_id"]) }
                    ?? nonEmptyString(change["terminal_id"])
                guard terminalID != nil else { return false }
            default:
                break
            }
        }
        for terminalID in affectedTerminalIDs {
            guard let terminal = next.terminals.first(where: { $0.id == terminalID }) else { continue }
            for tabID in terminal.tabIDs {
                guard let tab = next.tabs.first(where: { $0.id == tabID }) else { continue }
                guard tab.contentKind == "terminal", tab.contentID == terminalID else { return false }
            }
        }
        for browserID in affectedBrowserIDs {
            guard let browser = next.browsers.first(where: { $0.id == browserID }) else { continue }
            if let tab = next.tabs.first(where: { $0.id == browser.tabID }) {
                guard tab.contentKind == "browser", tab.contentID == browserID else { return false }
            }
        }
        // Agent terminal relationships are unique in the public schema. Check
        // the compact set once only when a batch touches an agent row.
        if changes.contains(where: { nonEmptyString($0["resource"]) == "agent" }) {
            var seen = Set<String>()
            for agent in next.agents {
                guard seen.insert(agent.terminalID).inserted else { return false }
            }
        }
        return true
    }

    private static func deltaImpact(
        _ changes: [[String: Any]],
        previous: CloudVMState,
        next: CloudVMState
    ) -> CloudVMStateDeltaImpact {
        var impact = CloudVMStateDeltaImpact()
        for change in changes {
            guard let resource = nonEmptyString(change["resource"]) else {
                impact.requiresFullResourceRebuild = true
                continue
            }
            let value = change["value"] as? [String: Any]
            guard let id = nonEmptyString(change["id"])
                ?? (resource == "agent"
                    ? nonEmptyString(change["terminal_id"])
                        ?? value.flatMap { nonEmptyString($0["id"]) ?? nonEmptyString($0["terminal_id"]) }
                    : nil)
            else {
                impact.requiresFullResourceRebuild = true
                continue
            }
            switch resource {
            case "terminal":
                let old = previous.terminals.first { $0.id == id }
                let current = next.terminals.first { $0.id == id }
                // A terminal's tab list is a relationship change. Its title, lifecycle, and
                // dimensions are row-local and can use the targeted path.
                if old?.tabIDs != current?.tabIDs {
                    impact.requiresFullResourceRebuild = true
                }
                impact.resourceIDs.insert(SurfaceResourceID(machine: next.machine, kind: .terminal, key: id))
            case "browser":
                let old = previous.browsers.first { $0.id == id }
                let current = next.browsers.first { $0.id == id }
                if old?.tabID != current?.tabID {
                    impact.requiresFullResourceRebuild = true
                }
                impact.resourceIDs.insert(SurfaceResourceID(machine: next.machine, kind: .browser, key: id))
            case "agent":
                let explicitID = nonEmptyString(change["id"])
                let valueTerminalID = (change["value"] as? [String: Any]).flatMap { nonEmptyString($0["terminal_id"]) }
                let oldTerminalID = previous.agents.first {
                    ($0.id == id) || (explicitID == nil && $0.terminalID == id)
                }?.terminalID
                // A reassigned agent changes two terminal rows: remove the old badge and
                // publish the new one. Deletes only have the old relationship.
                for terminalID in [oldTerminalID, valueTerminalID].compactMap({ $0 }) {
                    impact.resourceIDs.insert(SurfaceResourceID(machine: next.machine, kind: .terminal, key: terminalID))
                }
            case "tab":
                let old = previous.tabs.first { $0.id == id }
                let current = next.tabs.first { $0.id == id }
                guard current != nil || old != nil else {
                    impact.requiresFullResourceRebuild = true
                    continue
                }
                // A rename, focus, or index update stays on the same pane and content. A move
                // or content replacement changes placement joins and needs the full path.
                if let old,
                   let current,
                   old.paneID == current.paneID,
                   old.contentKind == current.contentKind,
                   old.contentID == current.contentID {
                    if let resourceID = resourceID(for: current.contentKind, contentID: current.contentID, machine: next.machine) {
                        impact.resourceIDs.insert(resourceID)
                    }
                } else {
                    // Creation and deletion change the terminal/browser/display placement
                    // graph even when the content id is known. A complete publication is the
                    // only way to update the affected content's tab list and ordering.
                    impact.requiresFullResourceRebuild = true
                }
            case "workspace", "screen", "pane", "machine", "session":
                // These entities are join roots. Their change can alter the placement or
                // ordering of many resources, so a complete rebuild is the safe boundary.
                impact.requiresFullResourceRebuild = true
            default:
                // Opaque entities are retained in CloudVMState but do not produce surface rows.
                break
            }
        }
        return impact
    }

    /// Checks duplicated envelope metadata when the daemon included it in the
    /// canonical payload. Older clients passed only `changes`, so absent
    /// optional metadata remains compatible; a present mismatch is a recovery
    /// barrier rather than a partially applied event.
    private static func deltaEnvelopeMatches(
        _ delta: [String: Any],
        cursor: CloudVMCursor,
        previousRevision: UInt64
    ) -> Bool {
        if let kind = delta["kind"] as? String, kind != "delta" { return false }
        if delta["kind"] != nil, delta["kind"] as? String == nil { return false }
        if let rawCursor = delta["cursor"] {
            guard let object = rawCursor as? [String: Any],
                  CloudVMCursor(wire: object) == cursor else { return false }
        }
        if let rawPrevious = delta["previous_revision"],
           CloudWireNumber.unsigned(rawPrevious) != previousRevision {
            return false
        }
        if let rawRevision = delta["revision"],
           CloudWireNumber.unsigned(rawRevision) != cursor.revision {
            return false
        }
        return true
    }

    /// Current daemons emit a zero-based sequence for every change. A legacy
    /// delta may omit the field entirely, but mixing present and absent values,
    /// repeating a sequence, or reordering it can hide a lost mutation.
    private static func deltaSequencesAreValid(_ changes: [[String: Any]]) -> Bool {
        var sawSequence = false
        var sawMissing = false
        for (index, change) in changes.enumerated() {
            guard let raw = change["sequence"] else {
                sawMissing = true
                continue
            }
            guard let sequence = CloudWireNumber.unsigned(raw), sequence == UInt64(index) else {
                return false
            }
            sawSequence = true
        }
        return !(sawSequence && sawMissing)
    }

    private static func resourceID(
        for contentKind: String,
        contentID: String,
        machine: SurfaceMachineID
    ) -> SurfaceResourceID? {
        guard !contentID.isEmpty else { return nil }
        switch contentKind {
        case "terminal": return SurfaceResourceID(machine: machine, kind: .terminal, key: contentID)
        case "browser": return SurfaceResourceID(machine: machine, kind: .browser, key: contentID)
        case "display", "screen": return SurfaceResourceID(machine: machine, kind: .display, key: contentID)
        default: return nil
        }
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
    private static func resources(
        fromSnapshot snapshot: [String: Any],
        machine: SurfaceMachineID,
        only resourceIDs: Set<SurfaceResourceID>? = nil
    ) -> [SurfaceResource] {
        // Raw one-shot callers do not pass through `state(fromSnapshot:)`.
        // Apply the same graph boundary here so they cannot construct a
        // resource with a placement borrowed from another tab.
        guard identityCollectionsAreUnique(in: snapshot),
              snapshotRelationshipsAreConsistent(in: snapshot)
        else { return [] }

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
        var contentKindOfTab: [String: String] = [:]
        var contentIDOfTab: [String: String] = [:]
        var nameOfTab: [String: String] = [:]
        var indexOfTab: [String: Int] = [:]
        var focusedOfTab: [String: Bool] = [:]
        for tab in tabsRaw {
            guard let id = tab["id"] as? String else { continue }
            if let paneID = tab["pane_id"] as? String {
                paneOfTab[id] = paneID
            }
            if let contentKind = nonEmptyString(tab["content_kind"]) {
                contentKindOfTab[id] = contentKind
            }
            if let contentID = nonEmptyString(tab["content_id"]) {
                contentIDOfTab[id] = contentID
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
            guard let terminalID = nonEmptyString(raw["id"]) else { continue }
            let resourceID = SurfaceResourceID(machine: machine, kind: .terminal, key: terminalID)
            if let resourceIDs, !resourceIDs.contains(resourceID) { continue }
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
            // Keep the PTY-derived title on the shared resource. User names belong to
            // each SurfaceRemoteView, because one terminal can have different tab labels.
            terminal.remoteViews = tabIDs.compactMap { tabID in
                guard let paneID = paneOfTab[tabID],
                      contentKindOfTab[tabID] == "terminal",
                      contentIDOfTab[tabID] == terminalID,
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
            guard let id = nonEmptyString(raw["id"]) else { continue }
            let resourceID = SurfaceResourceID(machine: machine, kind: .browser, key: id)
            if let resourceIDs, !resourceIDs.contains(resourceID) { continue }
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
            let resourceID = SurfaceResourceID(machine: machine, kind: .display, key: contentID)
            if let resourceIDs, !resourceIDs.contains(resourceID) { continue }
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
