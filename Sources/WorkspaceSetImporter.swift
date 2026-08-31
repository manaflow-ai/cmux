import Foundation
import Bonsplit
import Yams

// MARK: - Codable Types

struct WorkspaceSetFile: Codable {
    /// Optional template applied to every workspace: a list of named panels
    /// with optional startup commands.
    var defaultPanels: [WorkspaceSetPanelTemplate]?
    /// Optional layout tree referencing panel titles. Mirrors the session
    /// persistence layout format (split/pane nodes). When omitted, the
    /// default is a single pane containing all panels as tabs.
    var defaultLayout: WorkspaceSetLayoutNode?
    var sections: [WorkspaceSetSection]
    /// Optional declarations of named secondary windows pre-populated with
    /// subsets of the global workspace list. Absent or empty = single-window
    /// mode (today's behavior). Resolved by workspace name (case-insensitive)
    /// against entries declared under `sections`.
    var windows: [WorkspaceSetWindow]?
}

struct WorkspaceSetWindow: Codable {
    /// Display name for the window. Used as the NSWindow title (hidden in the
    /// UI but addressable) and as the case-insensitive identity key for
    /// `Reload Window Set` so existing windows aren't duplicated.
    var name: String
    /// Workspace names that should live in this window. Each name should
    /// match a `WorkspaceSetEntry.name` declared under `sections`. Missing
    /// names are logged and skipped — not fatal.
    var workspaces: [String]
}

struct WorkspaceSetSection: Codable {
    var name: String
    var collapsed: Bool?
    var workspaces: [WorkspaceSetEntry]
}

struct WorkspaceSetEntry: Codable {
    var name: String
    var directory: String
    var color: String?
    var description: String?
    var pinned: Bool?
    /// Per-workspace override of `defaultPanels`. When present, this entry's
    /// workspace gets exactly these panels instead of the file-wide defaults.
    /// Useful for a "fast" home workspace that opens a single Terminal pane
    /// without the SSH-spawning Claude/Files/Lazygit panels.
    var panels: [WorkspaceSetPanelTemplate]?
    /// Per-workspace override of `defaultLayout`. Required when `panels`
    /// references titles that don't exist in `defaultPanels`.
    var layout: WorkspaceSetLayoutNode?
}

struct WorkspaceSetPanelTemplate: Codable {
    var title: String
    var command: String?
}

/// An agent a workspace's agent pane can be pointed at. Duplicating a
/// workspace offers one of these so a copy can run Codex while the original
/// runs Claude (the workspace-set template only ever names one of them).
///
/// The wrapper scripts live in `~/.local/bin` and share a naming shape:
/// `<agent>` or `<agent>-<variant>` (`claude`, `claude-remote`, `codex-remote`).
/// Adding an agent is one case here plus its `panelTitle`.
enum WorkspaceAgent: String, CaseIterable, Sendable {
    case claude
    case codex

    /// Panel title the workspace-set templates use for this agent's pane.
    var panelTitle: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }

    /// Parse a CLI/socket argument (`claude`, `Codex`, `codex-remote`).
    init?(argument: String) {
        let normalized = argument.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        let head = normalized.split(separator: "-").first.map(String.init) ?? normalized
        guard let match = WorkspaceAgent(rawValue: head) else { return nil }
        self = match
    }
}

struct WorkspaceSetSplitLayout: Codable {
    var orientation: String  // "horizontal" or "vertical"
    var dividerPosition: Double
    var first: WorkspaceSetLayoutNode
    var second: WorkspaceSetLayoutNode
}

struct WorkspaceSetPaneLayout: Codable {
    var panels: [String]   // panel titles in tab order
    var selected: String?  // title of selected tab (defaults to first)
}

indirect enum WorkspaceSetLayoutNode: Codable {
    case split(WorkspaceSetSplitLayout)
    case pane(WorkspaceSetPaneLayout)

    private enum CodingKeys: String, CodingKey {
        case type, split, pane
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "split":
            self = .split(try c.decode(WorkspaceSetSplitLayout.self, forKey: .split))
        case "pane":
            self = .pane(try c.decode(WorkspaceSetPaneLayout.self, forKey: .pane))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c,
                debugDescription: "layout node type must be 'split' or 'pane', got '\(type)'"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .split(let s):
            try c.encode("split", forKey: .type)
            try c.encode(s, forKey: .split)
        case .pane(let p):
            try c.encode("pane", forKey: .type)
            try c.encode(p, forKey: .pane)
        }
    }
}

// MARK: - Import Result

struct WorkspaceSetImportResult {
    struct Created {
        let name: String
        let directory: String
        let section: String?
    }

    struct Skipped {
        let name: String
        let directory: String
        let reason: String
    }

    let created: [Created]
    let skipped: [Skipped]
    let sectionsCreated: [String]
    let panelsAdded: Int
}

// MARK: - Importer

@MainActor
enum WorkspaceSetImporter {

    /// Filenames probed inside `~/.config/cmux/`, in priority order.
    /// The first existing file wins; YAML is preferred over JSON so that a
    /// user who drops a `.yaml` next to an existing `.json` switches formats
    /// without having to delete the legacy file.
    private static let candidateFilenames: [String] = [
        "workspace-set.yaml",
        "workspace-set.yml",
        "workspace-set.json",
    ]

    /// Resolved path of the workspace-set file. Probes `~/.config/cmux/` for
    /// each candidate filename and returns the first one that exists on disk.
    /// When none exist, returns the `.json` fallback so error messages still
    /// reference a sensible path.
    static var defaultPath: String {
        let baseDir = (FileManager.default.homeDirectoryForCurrentUser.path
                       as NSString).appendingPathComponent(".config/cmux")
        let fm = FileManager.default
        for filename in candidateFilenames {
            let candidate = (baseDir as NSString).appendingPathComponent(filename)
            if fm.fileExists(atPath: candidate) { return candidate }
        }
        return (baseDir as NSString).appendingPathComponent("workspace-set.json")
    }

    static func fileExists(at path: String? = nil) -> Bool {
        FileManager.default.fileExists(atPath: path ?? defaultPath)
    }

    /// Parse the workspace-set file and return its `windows` declarations.
    /// Returns nil when no file exists or parsing fails; callers should treat
    /// nil and `[]` identically (single-window mode).
    static func windowDeclarations(at path: String? = nil) -> [WorkspaceSetWindow]? {
        guard let file = try? parseFile(at: path ?? defaultPath) else { return nil }
        return file.windows
    }

    /// Load and merge a workspace-set.json into the given TabManager.
    static func importFromFile(
        at path: String? = nil,
        into tabManager: TabManager,
        dryRun: Bool = false
    ) -> Result<WorkspaceSetImportResult, WorkspaceSetImportError> {
        let resolvedPath = path ?? defaultPath

        let workspaceSet: WorkspaceSetFile
        do {
            workspaceSet = try parseFile(at: resolvedPath)
        } catch let error as WorkspaceSetImportError {
            return .failure(error)
        } catch {
            return .failure(.readError(path: resolvedPath, underlying: error.localizedDescription))
        }

        let result = mergeInto(tabManager: tabManager, workspaceSet: workspaceSet, dryRun: dryRun)
        return .success(result)
    }

    /// Outcome of a single-workspace reconcile against the template.
    struct WorkspaceReconcileSummary {
        /// "rebuild" when the layout was torn down and recreated from the
        /// template (idle workspace), "fill" when only missing panels were
        /// added (running workspace), or "noop" when nothing needed to change.
        let action: String
        /// Number of panels touched: full template count for rebuild, missing
        /// panel count for fill, 0 for noop.
        let panelCount: Int
    }

    /// Reconcile a workspace against workspace-set.json without forcing a
    /// destructive rebuild. Idle workspaces are torn down and rebuilt from the
    /// template; running ones only get missing panels added so in-progress
    /// work isn't disrupted. Mirrors the per-workspace logic in `mergeInto`.
    static func reconcileWorkspace(
        _ workspace: Workspace,
        at path: String? = nil
    ) -> WorkspaceReconcileSummary? {
        let resolvedPath = path ?? defaultPath
        guard let workspaceSet = try? parseFile(at: resolvedPath) else { return nil }
        let matchingEntry = findEntry(for: workspace, in: workspaceSet)
        let templates: [WorkspaceSetPanelTemplate]?
        let layout: WorkspaceSetLayoutNode?
        if let entry = matchingEntry {
            templates = effectivePanels(for: entry, file: workspaceSet)
            layout = effectiveLayout(for: entry, file: workspaceSet)
        } else {
            templates = workspaceSet.defaultPanels
            layout = workspaceSet.defaultLayout
        }
        guard let templates, !templates.isEmpty else { return nil }

        // Bootstrap-state workspaces (one untitled panel that has never been
        // opened) get the full template applied so the user sees the
        // declared layout — Terminal/Claude/Files/Lazygit in the right
        // splits — the first time they click in. Already-materialized
        // workspaces stay additive: just fill any missing template panels
        // without tearing down what's there. This is the per-workspace
        // counterpart to the reload-time additive policy; here it's safe to
        // rebuild because it happens once per workspace on user action, not
        // 73x in a synchronous loop the way Reload Workspace Set did.
        if isWorkspaceBootstrapState(workspace) {
            let anchor = workspace.focusedPanelId
            for panelId in Array(workspace.panels.keys) where panelId != anchor {
                _ = workspace.closePanel(panelId, force: true)
            }
            applyFullTemplate(to: workspace, panels: templates, layout: layout)
            return WorkspaceReconcileSummary(action: "rebuild", panelCount: templates.count)
        }

        let added = fillMissingPanels(in: workspace, templates: templates)
        return WorkspaceReconcileSummary(action: added > 0 ? "fill" : "noop", panelCount: added)
    }

    /// True when a workspace has never been materialized from a template:
    /// at most one panel, no custom panel titles set, and no TTYs ever
    /// registered. Distinguishes "freshly created bootstrap" from "user
    /// opened it, ran the agent, agent exited" — the latter must be left
    /// alone so we don't trample on the user's actual work.
    private static func isWorkspaceBootstrapState(_ workspace: Workspace) -> Bool {
        workspace.panels.count <= 1
            && workspace.panelCustomTitles.isEmpty
            && workspace.surfaceTTYNames.isEmpty
    }

    /// Rebuild a single workspace's layout from the template in workspace-set.json.
    /// Replaces all panels and layout with the template; then runs each panel's command.
    @discardableResult
    static func rebuildWorkspaceFromTemplate(
        _ workspace: Workspace,
        at path: String? = nil,
        agent: WorkspaceAgent? = nil
    ) -> Int? {
        let resolvedPath = path ?? defaultPath
        guard let workspaceSet = try? parseFile(at: resolvedPath) else { return nil }
        let matchingEntry = findEntry(for: workspace, in: workspaceSet)
        let templates: [WorkspaceSetPanelTemplate]?
        let layout: WorkspaceSetLayoutNode?
        if let entry = matchingEntry {
            templates = effectivePanels(for: entry, file: workspaceSet)
            layout = effectiveLayout(for: entry, file: workspaceSet)
        } else {
            templates = workspaceSet.defaultPanels
            layout = workspaceSet.defaultLayout
        }
        guard var templates, !templates.isEmpty else { return nil }
        var resolvedLayout = layout
        if let agent {
            let retarget = retargeted(panels: templates, layout: layout, to: agent)
            templates = retarget.panels
            resolvedLayout = retarget.layout
        }

        // Reduce the workspace to a single pane with one anchor panel so
        // `restoreSessionSnapshot` doesn't layer new splits on top of the
        // existing layout. Close every non-anchor panel with force=true;
        // bonsplit collapses a pane when its last tab closes, so after this
        // the workspace is in the same shape as a newly-minted one.
        let anchor = workspace.focusedPanelId
        for panelId in Array(workspace.panels.keys) where panelId != anchor {
            _ = workspace.closePanel(panelId, force: true)
        }

        applyFullTemplate(to: workspace, panels: templates, layout: resolvedLayout)
        return templates.count
    }

    /// Rewrite an agent pane's template so it launches `agent` instead of the
    /// agent the workspace-set names. Panels that aren't agent panes are
    /// returned untouched, and a renamed panel is renamed in the layout tree
    /// too — `applyFullTemplate` resolves layout leaves by panel title.
    nonisolated static func retargeted(
        panels: [WorkspaceSetPanelTemplate],
        layout: WorkspaceSetLayoutNode?,
        to agent: WorkspaceAgent
    ) -> (panels: [WorkspaceSetPanelTemplate], layout: WorkspaceSetLayoutNode?) {
        var renames: [String: String] = [:]
        let rewritten = panels.map { tpl -> WorkspaceSetPanelTemplate in
            guard let command = tpl.command,
                  let swap = agentSwappedCommand(command, to: agent) else { return tpl }
            var copy = tpl
            copy.command = swap.command
            // Only retitle a pane that was named after the agent it ran; a
            // hand-titled pane ("Boards") keeps its name.
            if tpl.title.caseInsensitiveCompare(swap.previous.panelTitle) == .orderedSame {
                copy.title = agent.panelTitle
                renames[tpl.title.lowercased()] = agent.panelTitle
            }
            return copy
        }
        guard !renames.isEmpty else { return (rewritten, layout) }
        return (rewritten, layout.map { retitled($0, renames: renames) })
    }

    /// Swap the launched executable for `agent`'s equivalent, preserving any
    /// leading `VAR=value` env assignments, the wrapper's variant suffix and
    /// its directory: `CLAUDE_REMOTE_HOST=win-desktop claude-remote -n win`
    /// becomes `CLAUDE_REMOTE_HOST=win-desktop codex-remote -n win`.
    /// Returns nil when the command isn't an agent pane, or already runs `agent`.
    nonisolated private static func agentSwappedCommand(
        _ command: String,
        to agent: WorkspaceAgent
    ) -> (command: String, previous: WorkspaceAgent)? {
        var tokens = command.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard let index = tokens.firstIndex(where: { !$0.isEmpty && !isEnvAssignment($0) }) else { return nil }
        let token = tokens[index]
        let base = (token as NSString).lastPathComponent
        let lowered = base.lowercased()
        guard let previous = WorkspaceAgent.allCases.first(where: {
            lowered == $0.rawValue || lowered.hasPrefix($0.rawValue + "-")
        }), previous != agent else { return nil }
        let swappedBase = agent.rawValue + base.dropFirst(previous.rawValue.count)
        let directory = (token as NSString).deletingLastPathComponent
        tokens[index] = directory.isEmpty ? swappedBase : (directory as NSString).appendingPathComponent(swappedBase)
        return (tokens.joined(separator: " "), previous)
    }

    /// True for a shell env prefix like `CLAUDE_REMOTE_HOST=win-desktop`.
    nonisolated private static func isEnvAssignment(_ token: String) -> Bool {
        guard let equals = token.firstIndex(of: "="), equals != token.startIndex else { return false }
        let name = token[token.startIndex..<equals]
        guard let first = name.first, first.isLetter || first == "_" else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    nonisolated private static func retitled(
        _ node: WorkspaceSetLayoutNode,
        renames: [String: String]
    ) -> WorkspaceSetLayoutNode {
        switch node {
        case .split(let split):
            var copy = split
            copy.first = retitled(split.first, renames: renames)
            copy.second = retitled(split.second, renames: renames)
            return .split(copy)
        case .pane(let pane):
            var copy = pane
            copy.panels = pane.panels.map { renames[$0.lowercased()] ?? $0 }
            copy.selected = pane.selected.map { renames[$0.lowercased()] ?? $0 }
            return .pane(copy)
        }
    }

    // MARK: - Private

    private static func parseFile(at path: String) throws -> WorkspaceSetFile {
        guard FileManager.default.fileExists(atPath: path) else {
            throw WorkspaceSetImportError.fileNotFound(path: path)
        }
        guard let data = FileManager.default.contents(atPath: path), !data.isEmpty else {
            throw WorkspaceSetImportError.readError(path: path, underlying: "File is empty")
        }
        let ext = (path as NSString).pathExtension.lowercased()
        do {
            switch ext {
            case "yaml", "yml":
                return try YAMLDecoder().decode(WorkspaceSetFile.self, from: data)
            default:
                return try JSONDecoder().decode(WorkspaceSetFile.self, from: data)
            }
        } catch {
            throw WorkspaceSetImportError.parseError(path: path, underlying: error.localizedDescription)
        }
    }

    private static func mergeInto(
        tabManager: TabManager,
        workspaceSet: WorkspaceSetFile,
        dryRun: Bool
    ) -> WorkspaceSetImportResult {
        var existingByDir: [String: Workspace] = [:]
        for ws in tabManager.tabs {
            existingByDir[normalizedDirectoryKey(ws.currentDirectory)] = ws
        }

        var sectionByName: [String: SidebarSection] = [:]
        for section in tabManager.sections {
            let key = section.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !key.isEmpty { sectionByName[key] = section }
        }

        var created: [WorkspaceSetImportResult.Created] = []
        var skipped: [WorkspaceSetImportResult.Skipped] = []
        var sectionsCreated: [String] = []
        var panelsAdded = 0

        for sectionDef in workspaceSet.sections {
            let sectionName = sectionDef.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let sectionKey = sectionName.lowercased()
            let hasSection = !sectionName.isEmpty

            var targetSection: SidebarSection?
            if hasSection {
                if let existing = sectionByName[sectionKey] {
                    targetSection = existing
                } else if !dryRun {
                    let newSection = tabManager.createSection(name: sectionName, triggerRename: false)
                    if let collapsed = sectionDef.collapsed { newSection.setCollapsed(collapsed) }
                    sectionByName[sectionKey] = newSection
                    targetSection = newSection
                    sectionsCreated.append(sectionName)
                } else {
                    sectionsCreated.append(sectionName)
                }
            }

            for entry in sectionDef.workspaces {
                let expandedDir = (entry.directory as NSString).expandingTildeInPath
                let normalizedDir = normalizedDirectoryKey(expandedDir)

                let entryPanels = effectivePanels(for: entry, file: workspaceSet)

                if let existingWs = existingByDir[normalizedDir] {
                    if !dryRun {
                        // YAML is the source of truth for section grouping:
                        // if the entry declares a section, move the workspace
                        // there whether it was sectionless or in some other
                        // section. Lets users reorganize sidebar grouping via
                        // workspace-set.yaml + Reload Workspace Set.
                        if let section = targetSection,
                           tabManager.sectionForWorkspace(existingWs.id)?.id != section.id {
                            tabManager.moveWorkspaceToSection(tabId: existingWs.id, sectionId: section.id)
                        }
                        // Only fill panels into workspaces the user has
                        // actually opened. Bootstrap workspaces (created by a
                        // prior reload but never clicked) stay untouched so
                        // reload never spawns claude-pane/SSH/tmux for them —
                        // first-select reconcile applies the full template +
                        // commands when the user opens the workspace.
                        if let templates = entryPanels, !templates.isEmpty,
                           !isWorkspaceBootstrapState(existingWs) {
                            panelsAdded += fillMissingPanels(in: existingWs, templates: templates)
                        }
                    }
                    skipped.append(.init(name: entry.name, directory: entry.directory, reason: "directory_exists"))
                    continue
                }

                guard FileManager.default.fileExists(atPath: expandedDir) else {
                    skipped.append(.init(name: entry.name, directory: entry.directory, reason: "directory_missing"))
                    continue
                }

                if dryRun {
                    created.append(.init(name: entry.name, directory: entry.directory, section: hasSection ? sectionName : nil))
                    continue
                }

                // Create workspace (one bootstrap panel). Name comes from entry.name;
                // panel template + layout is applied right after via session-snapshot
                // rebuild so we get correct splits + divider positions.
                let ws = tabManager.addWorkspace(
                    title: entry.name,
                    workingDirectory: expandedDir,
                    select: false,
                    eagerLoadTerminal: false,
                    autoWelcomeIfNeeded: false
                )

                tabManager.setCustomTitle(tabId: ws.id, title: entry.name)
                if let description = entry.description {
                    tabManager.setCustomDescription(tabId: ws.id, description: description)
                }
                if let color = entry.color {
                    tabManager.setTabColor(tabId: ws.id, color: color)
                }
                if entry.pinned == true {
                    tabManager.setPinned(ws, pinned: true)
                }

                if let section = targetSection {
                    tabManager.moveWorkspaceToSection(tabId: ws.id, sectionId: section.id)
                }

                // Leave the new workspace in bootstrap state. Template +
                // commands (claude-pane, remote-pane lf, etc.) are deferred
                // to first-select reconcile. Eagerly applying templates here
                // meant Reload Workspace Set spawned tmux/SSH for every YAML
                // entry the user had never opened.

                existingByDir[normalizedDir] = ws

                created.append(.init(name: entry.name, directory: entry.directory, section: hasSection ? sectionName : nil))
            }
        }

        // Enforce YAML section order. Sections named in the YAML are moved
        // to the top in YAML order; sections not in YAML keep their relative
        // order below. This makes the YAML the source of truth for sidebar
        // layout instead of "wherever createSection happened to append."
        if !dryRun {
            applyYAMLSectionOrder(tabManager: tabManager, workspaceSet: workspaceSet)
        }

        return WorkspaceSetImportResult(
            created: created, skipped: skipped,
            sectionsCreated: sectionsCreated, panelsAdded: panelsAdded
        )
    }

    private static func applyYAMLSectionOrder(
        tabManager: TabManager,
        workspaceSet: WorkspaceSetFile
    ) {
        var targetIndex = 0
        for sectionDef in workspaceSet.sections {
            let key = sectionDef.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !key.isEmpty else { continue }
            guard let match = tabManager.sections.first(where: {
                $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == key
            }) else { continue }
            tabManager.reorderSection(sectionId: match.id, toIndex: targetIndex)
            targetIndex += 1
        }
    }

    // MARK: - Template application (full rebuild via session snapshot)

    /// Build a SessionWorkspaceSnapshot matching the requested template +
    /// layout and call `workspace.restoreSessionSnapshot(...)`. This gives us
    /// exact layout + divider positions out of the box.
    private static func applyFullTemplate(
        to workspace: Workspace,
        panels: [WorkspaceSetPanelTemplate],
        layout layoutNode: WorkspaceSetLayoutNode?
    ) {
        // Generate stable UUIDs per template title so the layout tree can
        // reference them.
        var panelIdByTitle: [String: UUID] = [:]
        for tpl in panels {
            panelIdByTitle[tpl.title.lowercased()] = UUID()
        }

        let cwd = workspace.currentDirectory

        let panelSnapshots: [SessionPanelSnapshot] = panels.map { tpl in
            let id = panelIdByTitle[tpl.title.lowercased()] ?? UUID()
            return SessionPanelSnapshot(
                id: id,
                type: .terminal,
                title: tpl.title,
                customTitle: tpl.title,
                directory: cwd,
                isPinned: false,
                isManuallyUnread: false,
                gitBranch: nil,
                listeningPorts: [],
                ttyName: nil,
                terminal: SessionTerminalPanelSnapshot(workingDirectory: cwd, scrollback: nil),
                browser: nil,
                markdown: nil
            )
        }

        let resolvedLayout: SessionWorkspaceLayoutSnapshot
        if let layoutNode {
            resolvedLayout = buildLayoutSnapshot(node: layoutNode, panelIdByTitle: panelIdByTitle,
                                                 fallbackIds: panels.map { panelIdByTitle[$0.title.lowercased()]! })
        } else {
            // Default: all panels as tabs in a single pane.
            let ids = panels.map { panelIdByTitle[$0.title.lowercased()]! }
            resolvedLayout = .pane(SessionPaneLayoutSnapshot(panelIds: ids, selectedPanelId: ids.first))
        }

        let firstId = panels.first.flatMap { panelIdByTitle[$0.title.lowercased()] }

        let snapshot = SessionWorkspaceSnapshot(
            id: workspace.id,
            processTitle: workspace.title,
            customTitle: workspace.customTitle,
            customDescription: workspace.customDescription,
            customColor: workspace.customColor,
            isPinned: workspace.isPinned,
            currentDirectory: cwd,
            // Preserve the workspace's instance index across the template
            // rebuild. `restoreSessionSnapshot` resets it to
            // `snapshot.instanceIndex ?? 1`, so omitting this would wipe the
            // duplicate's index back to the primary (1) — its panes would then
            // never export CMUX_WORKSPACE_INSTANCE, and claude-remote would
            // re-attach the source workspace's tmux session instead of opening
            // an independent "-<n>" one.
            instanceIndex: workspace.instanceIndex,
            focusedPanelId: firstId,
            layout: resolvedLayout,
            panels: panelSnapshots,
            statusEntries: [],
            logEntries: [],
            progress: nil,
            gitBranch: nil
        )

        workspace.restoreSessionSnapshot(snapshot)

        // Look up panels by their custom title after restore. The snapshot
        // UUIDs we generated above are remapped to fresh UUIDs by
        // createPanel; the custom title is preserved, so we match by that.
        var panelIdByTitleAfterRestore: [String: UUID] = [:]
        for (panelId, customTitle) in workspace.panelCustomTitles {
            panelIdByTitleAfterRestore[customTitle.lowercased()] = panelId
        }

        for tpl in panels {
            guard let cmd = tpl.command, !cmd.isEmpty else { continue }
            guard let panelId = panelIdByTitleAfterRestore[tpl.title.lowercased()] else { continue }
            sendCommand(to: panelId, in: workspace, command: cmd)
        }
    }

    /// Transform a WorkspaceSetLayoutNode (title-referenced) into a
    /// SessionWorkspaceLayoutSnapshot (UUID-referenced). Titles not in the
    /// panel set are silently skipped; panes emptied by this pruning get
    /// replaced with a fallback to avoid empty panes.
    private static func buildLayoutSnapshot(
        node: WorkspaceSetLayoutNode,
        panelIdByTitle: [String: UUID],
        fallbackIds: [UUID]
    ) -> SessionWorkspaceLayoutSnapshot {
        switch node {
        case .split(let s):
            let orientation: SessionSplitOrientation = s.orientation.lowercased() == "vertical" ? .vertical : .horizontal
            return .split(SessionSplitLayoutSnapshot(
                orientation: orientation,
                dividerPosition: s.dividerPosition,
                first: buildLayoutSnapshot(node: s.first, panelIdByTitle: panelIdByTitle, fallbackIds: fallbackIds),
                second: buildLayoutSnapshot(node: s.second, panelIdByTitle: panelIdByTitle, fallbackIds: fallbackIds)
            ))
        case .pane(let p):
            let ids = p.panels.compactMap { panelIdByTitle[$0.lowercased()] }
            let selected = p.selected.flatMap { panelIdByTitle[$0.lowercased()] } ?? ids.first
            if ids.isEmpty {
                // Should not happen with a valid layout; fall back to the
                // first template panel so bonsplit stays consistent.
                return .pane(SessionPaneLayoutSnapshot(panelIds: Array(fallbackIds.prefix(1)), selectedPanelId: fallbackIds.first))
            }
            return .pane(SessionPaneLayoutSnapshot(panelIds: ids, selectedPanelId: selected))
        }
    }

    // MARK: - Non-destructive fill of missing panels (Reload Workspace Set)

    /// For an existing workspace, add any template panels whose titles are
    /// missing. Existing panels are left alone to avoid disrupting running work.
    private static func fillMissingPanels(
        in workspace: Workspace,
        templates: [WorkspaceSetPanelTemplate]
    ) -> Int {
        guard !templates.isEmpty else { return 0 }

        var existingTitles = Set<String>()
        for (_, custom) in workspace.panelCustomTitles {
            let t = custom.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !t.isEmpty { existingTitles.insert(t) }
        }

        var missing: [WorkspaceSetPanelTemplate] = []
        for tpl in templates where !existingTitles.contains(tpl.title.lowercased()) {
            missing.append(tpl)
        }
        guard !missing.isEmpty else { return 0 }
        let totalMissing = missing.count

        // Find a pane already holding a non-first template panel so we add
        // tabs alongside it. Otherwise split right from the focused panel.
        let tabManager = workspace.owningTabManager
        var targetPaneId: PaneID?

        let nonFirstTitles = Set(templates.dropFirst().map { $0.title.lowercased() })
        for (panelId, custom) in workspace.panelCustomTitles {
            if nonFirstTitles.contains(custom.lowercased()),
               let pane = workspace.paneId(forPanelId: panelId) {
                targetPaneId = pane
                break
            }
        }

        if targetPaneId == nil {
            guard let anchor = workspace.focusedPanelId,
                  let newId = tabManager?.newSplit(
                    tabId: workspace.id, surfaceId: anchor,
                    direction: .right, focus: false
                  ) else {
                return 0
            }
            let first = missing.removeFirst()
            workspace.setPanelCustomTitle(panelId: newId, title: first.title)
            if let cmd = first.command { sendCommand(to: newId, in: workspace, command: cmd) }
            targetPaneId = workspace.paneId(forPanelId: newId)
        }

        guard let paneId = targetPaneId else { return 0 }

        for tpl in missing {
            guard let panel = workspace.newTerminalSurface(
                inPane: paneId, focus: false, workingDirectory: workspace.currentDirectory
            ) else { continue }
            workspace.setPanelCustomTitle(panelId: panel.id, title: tpl.title)
            if let cmd = tpl.command { sendCommand(to: panel.id, in: workspace, command: cmd) }
        }

        return totalMissing
    }

    private static func sendCommand(to panelId: UUID, in workspace: Workspace, command: String) {
        guard let terminalPanel = workspace.terminalPanel(for: panelId) else { return }
        terminalPanel.configuredCommand = command
        terminalPanel.sendText(command + "\n")
    }

    /// Resolve which panel templates apply to a given entry: the entry's
    /// own override if present, otherwise the file-wide `defaultPanels`.
    private static func effectivePanels(
        for entry: WorkspaceSetEntry,
        file: WorkspaceSetFile
    ) -> [WorkspaceSetPanelTemplate]? {
        entry.panels ?? file.defaultPanels
    }

    /// Resolve which layout applies. Per-entry layout wins; otherwise we
    /// only fall back to the file-wide default if it references panels that
    /// actually exist in the entry's effective panel set.
    private static func effectiveLayout(
        for entry: WorkspaceSetEntry,
        file: WorkspaceSetFile
    ) -> WorkspaceSetLayoutNode? {
        if let layout = entry.layout { return layout }
        // If the entry overrides panels, the file-wide layout likely refers
        // to titles that aren't in the override (Claude/Lazygit/Files etc.),
        // so let `applyFullTemplate` build a default single-pane layout.
        if entry.panels != nil { return nil }
        return file.defaultLayout
    }

    /// Locate the workspace-set entry matching a live workspace by directory.
    /// Used by `reconcileWorkspace` and `rebuildWorkspaceFromTemplate` to
    /// honor per-entry panel overrides without re-running the full merge.
    private static func findEntry(
        for workspace: Workspace,
        in file: WorkspaceSetFile
    ) -> WorkspaceSetEntry? {
        let key = normalizedDirectoryKey(workspace.currentDirectory)
        for section in file.sections {
            for entry in section.workspaces {
                let expanded = (entry.directory as NSString).expandingTildeInPath
                if normalizedDirectoryKey(expanded) == key {
                    return entry
                }
            }
        }
        return nil
    }

    private static func normalizedDirectoryKey(_ directory: String) -> String {
        var path = (directory as NSString).expandingTildeInPath
        path = (path as NSString).standardizingPath
        if path.hasSuffix("/"), path.count > 1 { path = String(path.dropLast()) }
        return path
    }
}

// MARK: - Error

enum WorkspaceSetImportError: Error, LocalizedError {
    case fileNotFound(path: String)
    case readError(path: String, underlying: String)
    case parseError(path: String, underlying: String)

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            return "Workspace set file not found: \(path)"
        case .readError(let path, let underlying):
            return "Failed to read workspace set file at \(path): \(underlying)"
        case .parseError(let path, let underlying):
            return "Failed to parse workspace set file at \(path): \(underlying)"
        }
    }
}
