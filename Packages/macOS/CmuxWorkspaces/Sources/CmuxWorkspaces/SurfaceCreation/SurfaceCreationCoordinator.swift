public import Foundation
public import Bonsplit
public import CmuxTerminalCore

/// Resolves the value-typed inputs a workspace computes when creating or
/// respawning a terminal surface: the startup working directory (chosen from an
/// ordered candidate list) and the inherited zoom font points (chosen from the
/// per-panel lineage root, the live runtime zoom, and the inherited Ghostty
/// config).
///
/// This is the package-pure core of the workspace's terminal-creation paths
/// (`newTerminalSplit`/`newTerminalSurface`/`respawnTerminalSurface`). The
/// surrounding bodies still live on the app-target `Workspace` because they
/// construct the app's `TerminalPanel`, mutate the workspace panel registry, and
/// call the Ghostty C bridges; those are the Wave-4 god-model decomposition and
/// will move behind a live-state ``SurfaceCreationHosting`` seam once
/// `TerminalPanel` is itself packaged. The two resolution rules lifted here
/// carry no live AppKit/Ghostty state: they are arithmetic and ordering over
/// `String?` and `Float?`, so the workspace gathers the candidate values (which
/// require reads of its own registry) and hands them to this resolver for the
/// final decision, exactly as the legacy private
/// `resolvedTerminalStartupWorkingDirectory(_:)`,
/// `normalizedTerminalWorkingDirectory(_:)`, and
/// `resolvedTerminalInheritanceFontPoints(_:)` bodies computed inline.
@MainActor
public final class SurfaceCreationCoordinator {
    /// Creates the resolver.
    ///
    /// `nonisolated` so the pure environment transforms
    /// (``sanitizedWorkspaceEnvironment(_:)``,
    /// ``startupEnvironment(workspaceEnvironment:overlaying:)``) can be reached
    /// from a fresh instance on the workspace's nonisolated socket
    /// workspace-create parsing path without hopping to the main actor. The
    /// coordinator holds no stored state, so constructing it off the main actor
    /// is trivially race-free.
    public nonisolated init() {}

    /// Trims whitespace/newlines from a requested working directory and maps an
    /// empty result to `nil`, mirroring the legacy
    /// `Workspace.normalizedTerminalWorkingDirectory`. Exposed so the workspace
    /// normalizes each candidate identically to the resolver.
    public nonisolated func normalizedWorkingDirectory(_ workingDirectory: String?) -> String? {
        let trimmed = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Picks the first non-empty normalized working directory from `candidates`,
    /// taken in the caller's order, mirroring the legacy
    /// `Workspace.resolvedTerminalStartupWorkingDirectory`. The workspace builds
    /// `candidates` as `[requestedWorkingDirectory, source panel reported cwd,
    /// source panel requested startup cwd, workspace currentDirectory]`; the
    /// resolver normalizes each (whitespace trim, empty → `nil`) and returns the
    /// first that survives, or `nil` when none do.
    public func resolvedStartupWorkingDirectory(candidates: [String?]) -> String? {
        candidates.lazy.compactMap(normalizedWorkingDirectory).first
    }

    /// Resolves the inherited zoom font points for a freshly created descendant
    /// terminal, mirroring the legacy `Workspace.resolvedTerminalInheritanceFontPoints`.
    ///
    /// - Parameters:
    ///   - rootedFontPoints: the panel-lineage root recorded in the workspace's
    ///     `terminalInheritanceFontPointsByPanelId` for the source panel, or
    ///     `nil`/non-positive when no lineage root exists.
    ///   - runtimeFontPoints: the source surface's current runtime zoom
    ///     (`cmuxCurrentSurfaceFontSizePoints`), or `nil` when unavailable.
    ///   - inheritedConfigFontPoints: the font size carried by the inherited
    ///     Ghostty config (`CmuxSurfaceConfigTemplate.fontSize`).
    /// - Returns: the rooted value when the lineage is seeded (promoting the
    ///   runtime value when a manual zoom diverged from the root by more than
    ///   0.05pt), otherwise the inherited config's positive font size, otherwise
    ///   the runtime value.
    public func resolvedInheritanceFontPoints(
        rootedFontPoints: Float?,
        runtimeFontPoints: Float?,
        inheritedConfigFontPoints: Float
    ) -> Float? {
        if let rooted = rootedFontPoints, rooted > 0 {
            if let runtimeFontPoints, abs(runtimeFontPoints - rooted) > 0.05 {
                // Runtime zoom changed after lineage was seeded (manual zoom on descendant);
                // treat runtime as the new root for future descendants.
                return runtimeFontPoints
            }
            return rooted
        }
        if inheritedConfigFontPoints > 0 {
            return inheritedConfigFontPoints
        }
        return runtimeFontPoints
    }

    /// Overlays a remote SSH startup environment onto the workspace's base
    /// startup environment, mirroring the legacy
    /// `Workspace.terminalStartupEnvironment(base:remoteStartupCommand:)`.
    ///
    /// The legacy body only merged the remote environment when BOTH a remote
    /// startup command was being used AND the workspace's `remoteConfiguration`
    /// exposed an `sshTerminalStartupEnvironment`; otherwise it returned `base`
    /// unchanged. Those two live-state reads stay on the workspace, which passes
    /// the already-resolved `remoteEnvironment` here as `nil` when either
    /// condition fails. When `remoteEnvironment` is non-`nil`, each of its
    /// key/value pairs is assigned over `base` (remote wins on key collisions),
    /// exactly as the legacy `environment[key] = value` loop did.
    ///
    /// - Parameters:
    ///   - base: the workspace startup environment (explicit overrides already
    ///     merged over the workspace environment).
    ///   - remoteEnvironment: the remote SSH terminal startup environment to
    ///     overlay, or `nil` when no remote command is in effect or the
    ///     workspace has no remote configuration.
    /// - Returns: `base` when `remoteEnvironment` is `nil`, otherwise `base`
    ///   with the remote pairs assigned over it.
    public nonisolated func mergedStartupEnvironment(
        base: [String: String],
        remoteEnvironment: [String: String]?
    ) -> [String: String] {
        guard let remoteEnvironment else { return base }
        var environment = base
        for (key, value) in remoteEnvironment {
            environment[key] = value
        }
        return environment
    }

    /// Normalizes a user-supplied workspace environment: trims keys and drops any
    /// entry with a blank key or blank value, mirroring the legacy
    /// `Workspace.sanitizedWorkspaceEnvironment`. Dropping blank values keeps
    /// behavior identical across the `additionalEnvironment` channel (which
    /// already skips empty values) and the `initialEnvironmentOverrides` channel
    /// (which would otherwise export a blank value on the initial shell only).
    ///
    /// Reserved `CMUX_*` variables are intentionally *not* stripped by name — they
    /// are protected at spawn time by `mergedStartupEnvironment(protectedKeys:)`,
    /// the single authority on which keys are managed. That protection is an exact
    /// Swift-string match, but the env eventually crosses the Swift→C boundary
    /// (`strdup` / Ghostty), where a key is truncated at its first NUL. A key like
    /// `"CMUX_SOCKET_PATH\0x"` would dodge the exact-match check yet collapse to
    /// `CMUX_SOCKET_PATH` in the spawned shell, so reject any key containing a NUL
    /// (and `=`, which is never a valid env var name) and any value containing a
    /// NUL. This is the single choke point for every entry point (CLI, cmux.json,
    /// session restore), so the guard cannot be bypassed.
    ///
    /// `nonisolated` so the workspace's nonisolated socket workspace-create
    /// parsing path (`v2WorkspaceCreate`) can call it without hopping to the main
    /// actor.
    ///
    /// - Parameter environment: the raw user-supplied workspace environment.
    /// - Returns: the sanitized environment with blank/invalid entries dropped.
    public nonisolated func sanitizedWorkspaceEnvironment(
        _ environment: [String: String]
    ) -> [String: String] {
        environment.reduce(into: [String: String]()) { result, pair in
            let key = pair.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty,
                  !pair.value.isEmpty,
                  !key.contains("\0"),
                  !key.contains("="),
                  !pair.value.contains("\0") else { return }
            result[key] = pair.value
        }
    }

    /// Pure merge core overlaying `explicit` on top of `workspaceEnvironment`,
    /// mirroring the legacy `Workspace.startupEnvironment(workspaceEnvironment:overlaying:)`.
    ///
    /// Managed `CMUX_*` / terminal-identity keys are protected downstream by
    /// `mergedStartupEnvironment(protectedKeys:)`; this only decides precedence
    /// among user-supplied values — explicit per-surface entries (layout `env`,
    /// scrollback replay, SSH startup) win over the workspace set. When the
    /// workspace environment is empty the explicit set is returned unchanged;
    /// otherwise each explicit pair is assigned over a copy of the workspace
    /// environment, exactly as the legacy body did.
    ///
    /// - Parameters:
    ///   - workspaceEnvironment: the sanitized workspace-wide environment.
    ///   - explicit: the per-surface explicit overrides that win on key collisions.
    /// - Returns: the precedence-merged startup environment.
    public nonisolated func startupEnvironment(
        workspaceEnvironment: [String: String],
        overlaying explicit: [String: String]
    ) -> [String: String] {
        guard !workspaceEnvironment.isEmpty else { return explicit }
        var merged = workspaceEnvironment
        for (key, value) in explicit {
            merged[key] = value
        }
        return merged
    }

    /// Trims whitespace/newlines from a requested remote-PTY session id and maps
    /// an empty result to `nil`, mirroring the legacy
    /// `Workspace.normalizedRemotePTYSessionID`.
    ///
    /// Pure `String?` normalization with no live state. The workspace routes
    /// every remote-PTY session id (restore, surface creation, relay alias
    /// resolution, detach transfer) through this so a blank or whitespace-only id
    /// is treated identically to `nil` everywhere, exactly as the legacy private
    /// helper did.
    ///
    /// - Parameter value: the raw session id (may be `nil`, empty, or padded).
    /// - Returns: the trimmed id, or `nil` when it is absent or whitespace-only.
    public nonisolated func normalizedRemotePTYSessionID(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    /// Normalizes a caller's requested initial command, mirroring the legacy
    /// inline `let explicitInitialCommand = (requestedInitialCommand?.isEmpty
    /// == false) ? requestedInitialCommand : nil` after the trim in
    /// `newTerminalSplitLocal`/`newTerminalSurfaceLocal`.
    ///
    /// Pure `String?` normalization: trims whitespace/newlines, then maps a
    /// `nil`-or-empty result to `nil` so an empty explicit command falls through
    /// to the remote startup command in
    /// ``resolveStartupCommand(explicitCommand:remoteCommand:)``.
    ///
    /// - Parameter initialCommand: the caller's requested initial command.
    /// - Returns: the trimmed command, or `nil` when it is absent or empty.
    public nonisolated func normalizedExplicitInitialCommand(_ initialCommand: String?) -> String? {
        let requested = initialCommand?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (requested?.isEmpty == false) ? requested : nil
    }

    /// Decides whether a freshly created terminal surface must be tracked as a
    /// remote terminal surface, mirroring the byte-identical inline derivation
    /// shared by `newTerminalSplitLocal` and `newTerminalSurfaceLocal`:
    ///
    /// ```swift
    /// let tracksRemoteTerminalSurface =
    ///     remoteTerminalStartupCommand != nil || normalizedRemotePTYSessionID != nil
    /// ```
    ///
    /// A surface is remote-tracked when it is launched with a remote startup
    /// command OR it carries a remote-PTY session id; either makes it a remote
    /// terminal the workspace must track (and untrack on a failed insert). The
    /// live reads (the workspace's resolved remote startup command and the
    /// already-normalized session id) stay on the workspace, which passes the
    /// resolved values here; this method owns only the pure OR decision so both
    /// creation paths apply the identical rule.
    ///
    /// - Parameters:
    ///   - remoteStartupCommand: the resolved remote startup command for the new
    ///     surface, or `nil` when none is in effect.
    ///   - normalizedRemotePTYSessionID: the already-normalized remote-PTY session
    ///     id (via ``normalizedRemotePTYSessionID(_:)``), or `nil` when absent.
    /// - Returns: `true` when either input is non-`nil`, matching the legacy
    ///   `remoteTerminalStartupCommand != nil || normalizedRemotePTYSessionID != nil`.
    public nonisolated func tracksRemoteTerminalSurface(
        remoteStartupCommand: String?,
        normalizedRemotePTYSessionID: String?
    ) -> Bool {
        remoteStartupCommand != nil || normalizedRemotePTYSessionID != nil
    }

    /// Resolves the startup command and the environment-fold remote command from
    /// the already-normalized explicit and remote commands, mirroring the
    /// byte-identical inline derivation shared by `newTerminalSplitLocal` and
    /// `newTerminalSurfaceLocal`:
    ///
    /// ```swift
    /// let startupCommand = explicitInitialCommand ?? remoteTerminalStartupCommand
    /// let remoteStartupCommandForEnvironment = explicitInitialCommand == nil ? remoteTerminalStartupCommand : nil
    /// ```
    ///
    /// The live read of the workspace's remote startup command (and the
    /// surface path's `suppressWorkspaceRemoteStartupCommand` gate) stays on the
    /// workspace, which passes the resolved `remoteCommand` here; this method owns
    /// only the pure pick. An explicit command fully replaces the remote command
    /// for launch AND removes the remote command from the environment overlay.
    ///
    /// - Parameters:
    ///   - explicitCommand: the normalized explicit initial command, or `nil`.
    ///   - remoteCommand: the workspace's remote startup command, or `nil`.
    /// - Returns: the resolved launch command and the remote command to fold into
    ///   the startup environment.
    public nonisolated func resolveStartupCommand(
        explicitCommand: String?,
        remoteCommand: String?
    ) -> TerminalStartupCommandResolution {
        TerminalStartupCommandResolution(
            startupCommand: explicitCommand ?? remoteCommand,
            remoteCommandForEnvironment: explicitCommand == nil ? remoteCommand : nil
        )
    }

    /// Walks the workspace's ordered inheritance-source candidates and returns
    /// the inherited Ghostty config for the new surface, mirroring the legacy
    /// `Workspace.inheritedTerminalConfig(preferredPanelId:inPane:)` exactly.
    ///
    /// The coordinator owns the pure decision (which candidate wins, how the
    /// rooted/runtime/inherited font points combine, when to seed lineage, and
    /// the last-known-font fallback); every live-state read and write is driven
    /// through ``SurfaceCreationHosting``. For each candidate the workspace
    /// supplies (in priority order), the walk asks the host for the candidate's
    /// live probe (`nil` when the panel no longer exposes a live surface, which
    /// the legacy body skipped via `guard let sourceSurface`). On the first live
    /// candidate it resolves the rooted font points
    /// (``resolvedInheritanceFontPoints(rootedFontPoints:runtimeFontPoints:inheritedConfigFontPoints:)``),
    /// applies a positive result to the config, then asks the host to commit the
    /// selection (seed the lineage root when positive, remember the inheritance
    /// source, record a positive final font size as the last-known value), and
    /// returns the config. When no candidate is live it synthesizes a fallback
    /// config from the host's last-known font points (or returns `nil` when there
    /// are none), matching the legacy fallback branch.
    ///
    /// - Parameters:
    ///   - host: the workspace live-state seam.
    ///   - preferredPanelId: the explicitly preferred inheritance-source panel,
    ///     forwarded to the host's candidate ordering.
    ///   - preferredPaneId: the target pane, forwarded to the host's candidate
    ///     ordering.
    /// - Returns: the inherited config to apply to the new surface, or `nil` when
    ///   there is no live candidate and no last-known font lineage.
    public func resolveInheritedConfig(
        host: any SurfaceCreationHosting,
        preferredPanelId: UUID? = nil,
        inPane preferredPaneId: PaneID? = nil
    ) -> CmuxSurfaceConfigTemplate? {
        // Walk candidates in priority order and use the first panel that still exposes
        // a runtime surface pointer.
        for panelId in host.configInheritanceCandidatePanelIds(
            preferredPanelId: preferredPanelId,
            inPane: preferredPaneId
        ) {
            guard let probe = host.probeInheritanceCandidate(panelId: panelId) else { continue }
            var config = probe.inheritedConfig
            // The lineage root to seed: the resolved value only when it is
            // positive, exactly as the legacy `rootedFontPoints > 0` branch
            // applied it to the config and wrote it back to the per-panel map.
            var rootedFontPointsToSeed: Float?
            if let rootedFontPoints = resolvedInheritanceFontPoints(
                rootedFontPoints: probe.rootedFontPoints,
                runtimeFontPoints: probe.runtimeFontPoints,
                inheritedConfigFontPoints: config.fontSize
            ), rootedFontPoints > 0 {
                config.fontSize = rootedFontPoints
                rootedFontPointsToSeed = rootedFontPoints
            }
            host.commitInheritanceSelection(
                panelId: panelId,
                rootedFontPoints: rootedFontPointsToSeed,
                finalConfigFontPoints: config.fontSize
            )
            return config
        }

        if let fallbackFontPoints = host.lastKnownInheritanceFontPoints {
            var config = CmuxSurfaceConfigTemplate()
            config.fontSize = fallbackFontPoints
            host.logInheritanceFallback(fontPoints: fallbackFontPoints)
            return config
        }

        return nil
    }

    /// Expands a leading `~` and standardizes a requested project path into the
    /// file URL the workspace hands to its `ProjectPanel`, mirroring the legacy
    /// inline `URL(fileURLWithPath: (projectPath as NSString).expandingTildeInPath)
    /// .standardizedFileURL` in `Workspace.newProjectSurface`.
    ///
    /// Pure path arithmetic with no live state: tilde expansion plus URL
    /// standardization (`.`/`..`/redundant-slash collapsing). The workspace still
    /// performs its own `projectPath.isEmpty` guard before calling, exactly as the
    /// legacy body did, so an empty path never reaches here.
    ///
    /// - Parameter projectPath: the requested project directory path (may begin
    ///   with `~`).
    /// - Returns: the standardized file URL for the project root.
    public nonisolated func standardizedProjectURL(projectPath: String) -> URL {
        URL(fileURLWithPath: (projectPath as NSString).expandingTildeInPath).standardizedFileURL
    }

    /// Creates a project surface tab in `paneId`, mirroring the legacy
    /// `Workspace.newProjectSurface(inPane:projectPath:focus:targetIndex:)` body
    /// step for step. The coordinator owns the create-tab orchestration; every
    /// live read and registry/bonsplit mutation is driven through
    /// ``SurfaceCreationHosting`` so the workspace registries and
    /// `BonsplitController` stay app-side. The package cannot name the app's
    /// `ProjectPanel`, so this returns the new panel's `id` (`nil` on guard
    /// failure or a failed tab insert) and the workspace maps it back to the
    /// typed panel via `panels[id] as? ProjectPanel`.
    ///
    /// The order is exact: guard the empty path, standardize the URL, read the
    /// focus decision and the previously focused panel/hosted-view before
    /// registration, register the panel (descriptor), create the tab (rolling the
    /// registration back on failure), reorder when an index is given, publish the
    /// created event, then either focus the new tab (focus pane → select tab →
    /// apply selection) or preserve focus on the previous panel, and finally
    /// reload the project panel.
    ///
    /// - Parameters:
    ///   - paneId: the pane that receives the new project surface.
    ///   - projectPath: the requested project directory path (may begin with `~`).
    ///   - focus: explicit focus intent, or `nil` to auto-focus only when
    ///     `paneId` is already the focused pane.
    ///   - targetIndex: an optional tab index to reorder the new tab to.
    ///   - host: the workspace live-state seam.
    /// - Returns: the new project panel's id, or `nil` when the path is empty or
    ///   the bonsplit tab could not be created.
    @discardableResult
    public func newProjectSurface(
        inPane paneId: PaneID,
        projectPath: String,
        focus: Bool?,
        targetIndex: Int?,
        host: any SurfaceCreationHosting
    ) -> UUID? {
        guard !projectPath.isEmpty else { return nil }
        let url = standardizedProjectURL(projectPath: projectPath)
        let shouldFocusNewTab = focus ?? (host.focusedBonsplitPaneId == paneId)
        let previousFocusedPanelId = host.focusedPanelId
        let previousHostedView = host.focusedTerminalHostedView

        let descriptor = host.registerProjectPanel(projectURL: url)

        guard let newTabId = host.createSurfaceTab(
            descriptor: descriptor,
            kind: SurfaceKind.project.rawValue,
            inPane: paneId
        ) else {
            host.discardPanelRegistration(id: descriptor.id)
            return nil
        }

        if let targetIndex {
            _ = host.reorderTab(newTabId, toIndex: targetIndex)
        }
        host.publishCmuxSurfaceCreated(
            descriptor.id,
            paneId: paneId,
            kind: SurfaceKind.project.rawValue,
            origin: "project_tab",
            focused: shouldFocusNewTab
        )
        if shouldFocusNewTab {
            host.focusPane(paneId)
            host.selectTab(newTabId)
            host.applyTabSelection(tabId: newTabId, inPane: paneId)
        } else {
            host.preserveSurfaceFocusAfterNonFocusSplit(
                preferredPanelId: previousFocusedPanelId,
                splitPanelId: descriptor.id,
                previousHostedView: previousHostedView
            )
        }

        host.reloadProjectPanel(id: descriptor.id)
        return descriptor.id
    }

    /// Creates a markdown surface tab in `paneId`, mirroring the legacy
    /// `Workspace.newMarkdownSurface(inPane:filePath:focus:targetIndex:)` body step
    /// for step. The coordinator owns the create-tab orchestration; every live read
    /// and registry/bonsplit mutation is driven through ``SurfaceCreationHosting``.
    /// The package cannot name the app's `MarkdownPanel`, so this returns the new
    /// panel's `id` (`nil` on a failed tab insert) and the workspace maps it back to
    /// the typed panel via `panels[id] as? MarkdownPanel`.
    ///
    /// Identical shape to ``newProjectSurface(inPane:projectPath:focus:targetIndex:host:)``
    /// except the panel is a markdown panel (registered with `isDirty` carried from
    /// the panel, not forced clean), the published kind/origin are `"markdown"`/
    /// `"markdown_tab"`, and the tail installs the markdown title/dirty subscription
    /// instead of reloading a project panel.
    ///
    /// - Parameters:
    ///   - paneId: the pane that receives the new markdown surface.
    ///   - filePath: the markdown file to display.
    ///   - focus: explicit focus intent, or `nil` to auto-focus only when `paneId`
    ///     is already the focused pane.
    ///   - targetIndex: an optional tab index to reorder the new tab to.
    ///   - host: the workspace live-state seam.
    /// - Returns: the new markdown panel's id, or `nil` when the bonsplit tab could
    ///   not be created.
    @discardableResult
    public func newMarkdownSurface(
        inPane paneId: PaneID,
        filePath: String,
        focus: Bool?,
        targetIndex: Int?,
        host: any SurfaceCreationHosting
    ) -> UUID? {
        let shouldFocusNewTab = focus ?? (host.focusedBonsplitPaneId == paneId)
        let previousFocusedPanelId = host.focusedPanelId
        let previousHostedView = host.focusedTerminalHostedView

        let descriptor = host.registerMarkdownPanel(filePath: filePath, fontSize: nil)

        guard let newTabId = host.createSurfaceTab(
            descriptor: descriptor,
            kind: SurfaceKind.markdown.rawValue,
            inPane: paneId
        ) else {
            host.discardPanelRegistration(id: descriptor.id)
            return nil
        }

        if let targetIndex {
            _ = host.reorderTab(newTabId, toIndex: targetIndex)
        }
        host.publishCmuxSurfaceCreated(
            descriptor.id,
            paneId: paneId,
            kind: "markdown",
            origin: "markdown_tab",
            focused: shouldFocusNewTab
        )
        if shouldFocusNewTab {
            host.focusPane(paneId)
            host.selectTab(newTabId)
            host.applyTabSelection(tabId: newTabId, inPane: paneId)
        } else {
            host.preserveSurfaceFocusAfterNonFocusSplit(
                preferredPanelId: previousFocusedPanelId,
                splitPanelId: descriptor.id,
                previousHostedView: previousHostedView
            )
        }

        host.installMarkdownPanelSubscription(id: descriptor.id)
        return descriptor.id
    }

    /// Splits off a new markdown surface from `panelId`, mirroring the legacy
    /// `Workspace.newMarkdownSplit(from:orientation:insertFirst:filePath:focus:fontSize:)`
    /// body step for step. The coordinator owns the orchestration; every live read,
    /// the `isProgrammaticSplit`-wrapped bonsplit split, and the registry mutations
    /// are driven through ``SurfaceCreationHosting``. Returns the new panel's `id`
    /// (`nil` when the panel has no pane or the split fails) which the workspace maps
    /// back to the typed `MarkdownPanel`.
    ///
    /// The order is exact: guard the source pane, register the panel, read the
    /// previously focused panel, split (rolling the registration back on failure),
    /// publish the split-created event, read the previous hosted view, then either
    /// suppress reparent focus and focus the new panel (focused branch) or preserve
    /// focus on the previous panel, and finally install the markdown subscription.
    ///
    /// - Parameters:
    ///   - panelId: the anchor panel the split originates from.
    ///   - orientation: the split orientation.
    ///   - insertFirst: whether the new pane is inserted before the source pane.
    ///   - filePath: the markdown file to display.
    ///   - focus: whether the new surface takes focus.
    ///   - fontSize: an optional initial markdown font size.
    ///   - host: the workspace live-state seam.
    /// - Returns: the new markdown panel's id, or `nil` on guard/split failure.
    @discardableResult
    public func newMarkdownSplit(
        fromPanelId panelId: UUID,
        orientation: SplitOrientation,
        insertFirst: Bool,
        filePath: String,
        focus: Bool,
        fontSize: Double?,
        host: any SurfaceCreationHosting
    ) -> UUID? {
        guard let paneId = host.paneId(forPanelId: panelId) else { return nil }

        let descriptor = host.registerMarkdownPanel(filePath: filePath, fontSize: fontSize)
        let previousFocusedPanelId = host.focusedPanelId

        guard let newPaneId = host.splitSurface(
            paneId,
            orientation: orientation,
            withTab: descriptor,
            kind: SurfaceKind.markdown.rawValue,
            insertFirst: insertFirst
        ) else {
            host.discardPanelRegistration(id: descriptor.id)
            return nil
        }
        host.publishCmuxSplitCreated(
            newPaneId,
            sourcePaneId: paneId,
            orientation: orientation,
            surfaceId: descriptor.id,
            kind: "markdown",
            origin: "markdown_split",
            focused: focus
        )

        let previousHostedView = host.focusedTerminalHostedView
        if focus {
            host.suppressReparentFocusUntilLayoutFollowUp(
                previousHostedView,
                reason: "workspace.markdownSplitReparent"
            )
            host.focusSurfacePanel(descriptor.id)
        } else {
            host.preserveSurfaceFocusAfterNonFocusSplit(
                preferredPanelId: previousFocusedPanelId,
                splitPanelId: descriptor.id,
                previousHostedView: previousHostedView
            )
        }

        host.installMarkdownPanelSubscription(id: descriptor.id)
        return descriptor.id
    }

    /// Splits `paneId` with a new markdown surface, mirroring the legacy
    /// `Workspace.splitPaneWithMarkdown(targetPane:orientation:insertFirst:filePath:)`
    /// body step for step. Unlike ``newMarkdownSplit(fromPanelId:orientation:insertFirst:filePath:focus:fontSize:host:)``
    /// this targets a pane directly (no `paneId(forPanelId:)` lookup), publishes no
    /// split event, and always focuses the new surface (select its tab, focus its
    /// panel). Returns the new panel's `id`, or `nil` when the split fails.
    ///
    /// - Parameters:
    ///   - paneId: the pane to split.
    ///   - orientation: the split orientation.
    ///   - insertFirst: whether the new pane is inserted before the source pane.
    ///   - filePath: the markdown file to display.
    ///   - host: the workspace live-state seam.
    /// - Returns: the new markdown panel's id, or `nil` on split failure.
    @discardableResult
    public func splitPaneWithMarkdown(
        targetPane paneId: PaneID,
        orientation: SplitOrientation,
        insertFirst: Bool,
        filePath: String,
        host: any SurfaceCreationHosting
    ) -> UUID? {
        let descriptor = host.registerMarkdownPanel(filePath: filePath, fontSize: nil)

        guard host.splitSurface(
            paneId,
            orientation: orientation,
            withTab: descriptor,
            kind: SurfaceKind.markdown.rawValue,
            insertFirst: insertFirst
        ) != nil else {
            host.discardPanelRegistration(id: descriptor.id)
            return nil
        }

        host.selectSurfaceTab(panelId: descriptor.id)
        host.focusSurfacePanel(descriptor.id)
        host.installMarkdownPanelSubscription(id: descriptor.id)
        return descriptor.id
    }

    /// Promotes the inherited surface config so the pane is held open after a
    /// startup command exits, mirroring the legacy inline block in
    /// `Workspace.newTerminalSplitLocal`/`newTerminalSurfaceLocal`:
    ///
    /// ```swift
    /// if startupCommand != nil {
    ///     var template = inheritedConfig ?? CmuxSurfaceConfigTemplate()
    ///     template.waitAfterCommand = true
    ///     inheritedConfig = template
    /// }
    /// ```
    ///
    /// Holding the PTY open lets the user read a message a remote/login startup
    /// command prints before exiting; otherwise Ghostty silently respawns a
    /// local login shell, making a dead VM look identical to a healthy local
    /// prompt. When no startup command is in effect the inherited config is
    /// returned unchanged (including `nil`).
    ///
    /// - Parameters:
    ///   - inheritedConfig: the config inherited from the source surface, or
    ///     `nil` when there is no inheritance source.
    ///   - hasStartupCommand: whether a startup command (explicit or the remote
    ///     workspace command) will run in the new surface.
    /// - Returns: the unchanged `inheritedConfig` when `hasStartupCommand` is
    ///   `false`; otherwise the inherited config (or a fresh template) with
    ///   `waitAfterCommand` set to `true`.
    public nonisolated func configHoldingPaneAfterStartupCommand(
        inheritedConfig: CmuxSurfaceConfigTemplate?,
        hasStartupCommand: Bool
    ) -> CmuxSurfaceConfigTemplate? {
        guard hasStartupCommand else { return inheritedConfig }
        var template = inheritedConfig ?? CmuxSurfaceConfigTemplate()
        template.waitAfterCommand = true
        return template
    }
}
