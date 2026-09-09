import Foundation

/// Pure remote catalog selector and placement resolution shared by the app and CLI.
enum CmuxTuiRemoteRouting {
    /// Where `cmux vm open <target>` points. Grammar:
    ///   <machine>                      the machine's shell (the shared vmOpenShell path)
    ///   <machine>/<workspace>          a cmux-tui workspace on the machine (`ws_…` id or unique name)
    ///   <machine>/<workspace>/<term>   one terminal in it (`term_…`)
    ///   <machine>:desktop              the machine's noVNC screen
    ///   <machine>:port/<n>             a forwarded HTTP port
    /// The same addresses appear in `cmux vm tree`, so an agent can copy them verbatim.
    enum VMOpenTarget: Equatable {
        case machine(String)
        case workspace(machine: String, workspace: String)
        case terminal(machine: String, workspace: String, terminal: String)
        case desktop(String)
        case port(machine: String, port: Int)

        var machine: String {
            switch self {
            case .machine(let id), .desktop(let id):
                return id
            case .workspace(let id, _), .terminal(let id, _, _), .port(let id, _):
                return id
            }
        }
    }

    /// Resolution of a remote workspace selector. Workspace ids are identities;
    /// names are mutable labels and are accepted only when they identify one row.
    /// Keeping this result explicit prevents a missing or ambiguous catalog from
    /// falling through to an arbitrary `.first` match.
    enum VMRemoteWorkspaceSelectorResolution: Equatable {
        case resolved(String)
        case notFound
        case ambiguous([String])
        case unavailable
    }

    /// Resolve one `<machine>/<workspace>` selector against the machine row from
    /// `surface.catalog`. The machine's `remote_workspaces` list is authoritative,
    /// because it also contains empty workspaces that cannot be recovered from the
    /// terminal rows. Exact ids win over names, including when an id equals another
    /// workspace's name. A name must be unique; otherwise the caller must use an id.
    static func resolveVMRemoteWorkspaceSelector(
        _ rawSelector: String,
        in machinePayload: [String: Any]
    ) -> VMRemoteWorkspaceSelectorResolution {
        let selector = rawSelector.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selector.isEmpty else { return .notFound }
        guard let rawWorkspaces = machinePayload["remote_workspaces"] as? [[String: Any]] else {
            return .unavailable
        }
        let workspaces = rawWorkspaces.compactMap { workspace -> (id: String, name: String)? in
            guard let id = workspace["id"] as? String, !id.isEmpty,
                  let name = workspace["name"] as? String else { return nil }
            return (id: id, name: name)
        }

        let exactIDMatches = workspaces.filter { $0.id == selector }
        if exactIDMatches.count == 1 { return .resolved(exactIDMatches[0].id) }
        if exactIDMatches.count > 1 {
            return .ambiguous(exactIDMatches.map(\.id))
        }

        let nameMatches = workspaces.filter { $0.name == selector }
        switch nameMatches.count {
        case 0: return .notFound
        case 1: return .resolved(nameMatches[0].id)
        default: return .ambiguous(nameMatches.map(\.id))
        }
    }

    /// Return the machine row from a catalog payload. A filtered catalog should
    /// contain one row, so duplicate rows are treated as unavailable rather than
    /// selecting one by array order.
    static func vmMachinePayload(
        _ machine: String,
        from catalog: [String: Any]
    ) -> [String: Any]? {
        let matches = ((catalog["machines"] as? [[String: Any]]) ?? [])
            .filter { ($0["id"] as? String) == machine }
        guard matches.count == 1 else { return nil }
        return matches[0]
    }

    enum VMRemoteViewResolution {
        case resolved([String: Any])
        /// A legacy resource identifies one workspace but has no tab id. Whole
        /// workspace opens may use that relationship; exact terminal selectors
        /// must still fail closed.
        case legacy
        case notFound
        case ambiguous
        case unavailable
    }

    /// The safe first terminal for a whole-workspace open. One unresolved
    /// terminal must not veto another terminal whose placement is known, while
    /// an unresolved result remains available when there is no safe candidate.
    enum VMRemoteWorkspaceTerminalResolution: Equatable {
        case resolved(terminalID: String, tabID: String?)
        case none
        case ambiguous(selector: String)
        case unavailable(selector: String)
    }

    /// Resolve the terminal a whole-workspace open should show. Exited rows are
    /// not candidates: their stale or partial placement data cannot block a live
    /// terminal. Among live rows, all safe candidates are collected before an
    /// ambiguity or unavailable result is returned, so an early bad row cannot
    /// hide a later safe row.
    static func resolveVMRemoteWorkspaceTerminal(
        _ resources: [[String: Any]],
        machine: String,
        workspaceID: String
    ) -> VMRemoteWorkspaceTerminalResolution {
        let liveTerminals = resources.filter { resource in
            (resource["kind"] as? String) == "terminal" && (resource["lifecycle"] as? String) != "exited"
        }
        var candidates: [(terminalID: String, tabID: String?, focused: Bool, sortID: String)] = []
        var ambiguousSelectors: [String] = []
        var unavailableSelectors: [String] = []

        for terminal in liveTerminals {
            let selector = (terminal["key"] as? String) ?? (terminal["id"] as? String) ?? "?"
            switch resolveVMRemoteView(in: terminal, workspaceID: workspaceID) {
            case .resolved(let view):
                guard let terminalID = vmTerminalID(in: terminal, machine: machine) else {
                    unavailableSelectors.append(selector)
                    continue
                }
                let tabID = (view["tab_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let tabID, !tabID.isEmpty else {
                    unavailableSelectors.append(selector)
                    continue
                }
                candidates.append((terminalID, tabID, (view["focused"] as? Bool) == true, selector))
            case .legacy:
                guard let terminalID = vmTerminalID(in: terminal, machine: machine) else {
                    unavailableSelectors.append(selector)
                    continue
                }
                candidates.append((terminalID, nil, false, selector))
            case .notFound:
                continue
            case .ambiguous:
                ambiguousSelectors.append(selector)
            case .unavailable:
                unavailableSelectors.append(selector)
            }
        }

        let focusedFirst = candidates.sorted { lhs, rhs in
            if lhs.focused != rhs.focused { return lhs.focused && !rhs.focused }
            if lhs.sortID != rhs.sortID { return lhs.sortID < rhs.sortID }
            return (lhs.tabID ?? "") < (rhs.tabID ?? "")
        }
        if let pick = focusedFirst.first {
            return .resolved(terminalID: pick.terminalID, tabID: pick.tabID)
        }
        // An unavailable catalog is less actionable than a placement ambiguity:
        // tell the caller to reconnect instead of asking it to choose from stale
        // rows. Both are reported only after every live row proved unsafe.
        if let selector = unavailableSelectors.sorted().first {
            return .unavailable(selector: selector)
        }
        if let selector = ambiguousSelectors.sorted().first {
            return .ambiguous(selector: selector)
        }
        return .none
    }

    /// Resolve a resource's exact view in one remote workspace. A view row is required for
    /// focused/tab placement. A legacy single-workspace resource is returned as `.legacy` so
    /// workspace opens can preserve the terminal-id fallback while exact selectors fail.
    static func resolveVMRemoteView(
        in resource: [String: Any],
        workspaceID: String
    ) -> VMRemoteViewResolution {
        if let views = resource["remote_views"] as? [[String: Any]] {
            let matches = views.filter { view in
                let workspace = view["workspace"] as? [String: Any]
                return (workspace?["id"] as? String) == workspaceID
            }
            guard !matches.isEmpty else { return .notFound }
            let candidate: [String: Any]
            if matches.count == 1 {
                candidate = matches[0]
            } else {
                // A terminal may occur in several tabs of the same workspace. The focused
                // tab is the only safe implicit choice; zero or multiple focused tabs stay
                // unresolved instead of selecting by array order.
                let focused = matches.filter { ($0["focused"] as? Bool) == true }
                guard focused.count == 1 else { return .ambiguous }
                candidate = focused[0]
            }
            guard let tabID = (candidate["tab_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !tabID.isEmpty else {
                return .unavailable
            }
            guard views.filter({ ($0["tab_id"] as? String) == tabID }).count == 1 else {
                return .ambiguous
            }
            return .resolved(candidate)
        }
        guard let workspace = resource["remote_workspace"] as? [String: Any],
              (workspace["id"] as? String) == workspaceID else {
            return .notFound
        }
        return .legacy
    }

    /// Find a resource's exact view in one remote workspace. The view row is
    /// required for focused/tab placement; the legacy single-workspace field is
    /// retained as a compatibility fallback for providers without multi-view data.
    static func vmRemoteView(
        in resource: [String: Any],
        workspaceID: String
    ) -> [String: Any]? {
        guard case .resolved(let view) = resolveVMRemoteView(in: resource, workspaceID: workspaceID) else {
            return nil
        }
        return view
    }

    /// Resolves a terminal selector to one daemon tab. A terminal can be shown in several
    /// tabs, so its id alone does not identify the placement whose name or pane the caller
    /// means. The returned tab id is passed to `surface.project` as a placement fence.
    enum VMRemoteTerminalPlacementResolution: Equatable {
        case resolved(terminalID: String, tabID: String)
        case notFound
        case ambiguous
        case unavailable
    }

    static func resolveVMRemoteTerminalPlacement(
        _ rawSelector: String,
        machine: String,
        workspaceID: String,
        in catalog: [String: Any]
    ) -> VMRemoteTerminalPlacementResolution {
        let selector = rawSelector.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selector.isEmpty, !machine.isEmpty, !workspaceID.isEmpty else { return .notFound }
        guard let rawResources = catalog["resources"] as? [[String: Any]] else { return .unavailable }

        let resources = rawResources.filter { resource in
            guard (resource["kind"] as? String) == "terminal" else { return false }
            if let resourceMachine = resource["machine"] as? String {
                return resourceMachine == machine
            }
            guard let id = resource["id"] as? String else { return false }
            return id.hasPrefix("\(machine)/terminal/")
        }

        // Full resource ids take precedence over keys. This prevents a malformed or mutable
        // key from shadowing an exact identity, matching workspace selector semantics.
        let fullID = "\(machine)/terminal/\(selector)"
        let exactIDMatches = resources.filter { resource in
            guard let id = resource["id"] as? String else { return false }
            return id == selector || id == fullID
        }
        let matchedByExactID = !exactIDMatches.isEmpty
        let candidates = matchedByExactID
            ? exactIDMatches
            : resources.filter { ($0["key"] as? String) == selector }
        guard candidates.count == 1, let resource = candidates.first else {
            return candidates.isEmpty ? .notFound : .ambiguous
        }

        let tabID: String
        switch resolveVMRemoteView(in: resource, workspaceID: workspaceID) {
        case .resolved(let view):
            guard let value = (view["tab_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
                return .unavailable
            }
            tabID = value
        case .legacy:
            // An exact terminal selector cannot safely invent a tab id.
            return .unavailable
        case .notFound:
            return .notFound
        case .ambiguous:
            return .ambiguous
        case .unavailable:
            return .unavailable
        }

        let terminalID = vmTerminalID(in: resource, machine: machine)
        guard let terminalID, !terminalID.isEmpty else { return .unavailable }
        return .resolved(terminalID: terminalID, tabID: tabID)
    }

    /// Returns the terminal key accepted by `surface.project` from either a
    /// catalog's explicit `key` or its canonical resource id. Keeping this in
    /// one helper prevents callers from sending a full id where a key is
    /// required and producing `machine/terminal/machine/terminal/key`.
    static func vmTerminalID(in resource: [String: Any], machine: String) -> String? {
        if let key = (resource["key"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            // `key` is the final path component. A complete resource id would be
            // prefixed again by callers and route to a different terminal.
            guard !key.contains("/") else { return vmTerminalIDFromCanonicalID(in: resource, machine: machine) }
            return key
        }
        return vmTerminalIDFromCanonicalID(in: resource, machine: machine)
    }

    private static func vmTerminalIDFromCanonicalID(in resource: [String: Any], machine: String) -> String? {
        guard let id = (resource["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else {
            return nil
        }
        let prefix = "\(machine)/terminal/"
        if id.hasPrefix(prefix) {
            let key = String(id.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            return key.isEmpty ? nil : key
        }
        // A few older catalog producers emitted the terminal key as `id`.
        // Accept it only when it has no path separators, so a different
        // machine's canonical id cannot be routed to this machine.
        return id.contains("/") ? nil : id
    }
}
