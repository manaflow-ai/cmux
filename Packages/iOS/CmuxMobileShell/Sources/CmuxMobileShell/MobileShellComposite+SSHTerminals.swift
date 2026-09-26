public import CmuxMobileShellModel
import Foundation

/// Terminal tabs on SSH computers: "New Terminal" and pane geometry.
///
/// - tmux: a tab is a pane; New Terminal opens a tmux window.
/// - cmux-tui: New Terminal creates a terminal in the cmux-tui workspace.
/// - plain: one shell per workspace, so there are no terminal tabs.
@MainActor
extension MobileShellComposite {
    /// Whether "New Terminal" applies to this workspace row. `false` only
    /// for plain-shell SSH workspaces; Mac and other rows return `true`.
    public func sshSupportsTerminalTabs(workspaceID: MobileWorkspacePreview.ID) -> Bool {
        guard sshOwnsWorkspaceRow(workspaceID), let scoped = sshScopedWorkspaceID(workspaceID) else { return true }
        return sshComputers.supportsTerminalTabs(workspaceID: scoped)
    }

    /// The SSH branch of ``createTerminal(in:)`` ("New Window" for tmux,
    /// "New Screen" for cmux-tui): creates it on the server, then selects
    /// its terminal once the refreshed row lists it.
    func createSSHTerminal(in workspaceID: MobileWorkspacePreview.ID) {
        guard let scoped = sshScopedWorkspaceID(workspaceID),
              sshComputers.supportsTerminalTabs(workspaceID: scoped) else { return }
        selectedWorkspaceID = workspaceID
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.selectCreatedSSHTerminal(await self.sshComputers.createTerminal(inWorkspace: scoped))
        }
    }

    /// The grouped tab switcher of an SSH workspace row (PRD D32); `nil`
    /// for Mac rows and shells, whose switchers stay flat.
    public func sshTabLayout(workspaceID: MobileWorkspacePreview.ID) -> MobileSSHTabLayout? {
        guard sshOwnsWorkspaceRow(workspaceID), let scoped = sshScopedWorkspaceID(workspaceID) else { return nil }
        return sshComputers.tabLayout(workspaceID: scoped)
    }

    /// The kind of an SSH workspace row; `nil` for Mac rows.
    public func sshWorkspaceKind(workspaceID: MobileWorkspacePreview.ID) -> MobileSSHWorkspaceKind? {
        guard sshOwnsWorkspaceRow(workspaceID), let scoped = sshScopedWorkspaceID(workspaceID) else { return nil }
        return sshComputers.kind(ofScopedID: scoped)
    }

    /// A section's action from the grouped switcher: "Split Pane" on a tmux
    /// window; "New Tab" or "Split Pane" on a cmux-tui screen. `nil` runs
    /// the section's first action. Selects the new terminal.
    public func createSSHTab(
        in workspaceID: MobileWorkspacePreview.ID,
        section sectionID: String,
        action: MobileSSHSectionAction? = nil
    ) {
        guard let scoped = sshScopedWorkspaceID(workspaceID) else { return }
        selectedWorkspaceID = workspaceID
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.selectCreatedSSHTerminal(await self.sshComputers.createTab(inWorkspace: scoped, section: sectionID, action: action))
        }
    }

    private func selectCreatedSSHTerminal(_ terminal: String?) {
        guard let terminal else { return }
        let id = MobileTerminalPreview.ID(rawValue: terminal)
        // Rows are published before this runs; aggregation keeps SSH
        // terminal ids unscoped (they already carry the host namespace).
        guard workspaces.contains(where: { $0.terminals.contains { $0.id == id } }) else { return }
        selectedMacSurfaceID = nil
        selectedTerminalID = id
    }

    /// The SSH-namespaced id (`cmux-ssh-<host>~<local>`) of a workspace row.
    ///
    /// With more than one computer in the list, aggregation re-keys every row
    /// as `<owner id><US><local id>`. An SSH computer's owner id is itself
    /// `cmux-ssh-<host>`, so the re-keyed row id still starts with the SSH
    /// prefix but no longer parses; the row's RPC id keeps the scoped id.
    /// Resolve through the row first and accept a raw id only when it parses.
    public func sshScopedWorkspaceID(_ id: MobileWorkspacePreview.ID) -> String? {
        if let row = workspaces.first(where: { $0.id == id }) {
            let rpcID = row.rpcWorkspaceID.rawValue
            return MobileSSHIdentifier(rpcID).isScoped ? rpcID : nil
        }
        return MobileSSHIdentifier(id.rawValue).isScoped ? id.rawValue : nil
    }

    // MARK: Pane geometry

    /// How SSH output sizes the surface: a tmux pane renders at its layout
    /// size (the surface pins to that grid and letterboxes); every other SSH
    /// surface uses the phone's own grid.
    func sshViewportPolicy(surfaceID: String) -> MobileTerminalOutputViewportPolicy {
        guard let grid = sshComputers.remoteGrid(surfaceID: surfaceID) else { return .natural }
        return .remoteGrid(columns: grid.columns, rows: grid.rows)
    }

    func sshApplyViewport(surfaceID: String) {
        _ = deliverTerminalOutput(
            TerminalOutputDelivery(
                bytes: Data(),
                replaceable: true,
                replacementScope: .viewportPolicy,
                viewportPolicy: sshViewportPolicy(surfaceID: surfaceID),
                requiresVerifiedReplay: false
            ),
            surfaceID: surfaceID,
            bypassReplayBarrier: true
        )
    }
}

/// The grouped tab switcher of one SSH workspace (PRD D32): tmux windows
/// or cmux-tui screens as sections, pane/tab terminals as rows.
public struct MobileSSHTabLayout: Equatable, Sendable {
    public var kind: MobileSSHWorkspaceKind
    public var sections: [MobileSSHTabSection]

    public init(kind: MobileSSHWorkspaceKind, sections: [MobileSSHTabSection]) {
        self.kind = kind
        self.sections = sections
    }
}

/// A section-level create action of the grouped switcher (PRD D32).
public enum MobileSSHSectionAction: String, Sendable, Equatable, CaseIterable {
    /// cmux-tui: a terminal tab in the screen's active pane (`new-tab`).
    case newTab
    /// Splits the section's active pane: tmux `split-window -d` on the
    /// window, cmux-tui `split` on the screen.
    case splitPane
}

/// One tmux window or cmux-tui screen.
public struct MobileSSHTabSection: Equatable, Sendable, Identifiable {
    /// Section id within the workspace (tmux window index, cmux-tui screen id).
    public var id: String
    public var title: String
    public var rows: [MobileSSHTabRow]
    /// The section's create actions, in menu order: "Split Pane" on a tmux
    /// window; "New Tab" then "Split Pane" on a cmux-tui screen with a pane
    /// to act on.
    public var actions: [MobileSSHSectionAction]

    /// Whether the section has any create action.
    public var canAddTab: Bool { !actions.isEmpty }

    public init(id: String, title: String, rows: [MobileSSHTabRow], actions: [MobileSSHSectionAction]) {
        self.id = id
        self.title = title
        self.rows = rows
        self.actions = actions
    }
}

/// One terminal tab inside a section.
public struct MobileSSHTabRow: Equatable, Sendable, Identifiable {
    /// The terminal's surface id (the workspace row's terminal id).
    public var id: String
    public var title: String
    /// Names the pane when the section has several (`Pane 2`).
    public var paneLabel: String?
    /// The first row of a pane after another pane's rows, where the
    /// switcher draws a separator.
    public var startsPane: Bool

    public init(id: String, title: String, paneLabel: String?, startsPane: Bool) {
        self.id = id
        self.title = title
        self.paneLabel = paneLabel
        self.startsPane = startsPane
    }
}

@MainActor
extension MobileSSHComputers {
    /// Whether a workspace can gain terminal tabs (tmux, cmux-tui); a shell
    /// is one terminal.
    func supportsTerminalTabs(workspaceID scopedID: String) -> Bool {
        guard let kind = kind(ofScopedID: scopedID) else { return false }
        return kind != .shell
    }

    /// The grouped tab switcher for an SSH workspace row; `nil` for shells
    /// and unknown rows.
    public func tabLayout(workspaceID scopedID: String) -> MobileSSHTabLayout? {
        guard let hostID = MobileSSHIdentifier(scopedID).hostID,
              let local = MobileSSHIdentifier(scopedID).localID,
              let workspace = workspacesByHostSnapshot(hostID)?.first(where: { $0.id == local }),
              workspace.kind != .shell else { return nil }
        return Self.tabLayout(workspace, hostID: hostID)
    }

    nonisolated static func tabLayout(_ workspace: MobileSSHWorkspace, hostID: UUID) -> MobileSSHTabLayout {
        var sections = workspace.sections.map { section in
            MobileSSHTabSection(
                id: section.id,
                title: section.title,
                rows: [],
                actions: sectionActions(kind: workspace.kind, targetPane: section.targetPane)
            )
        }
        var lastPane: [String: String] = [:]
        for terminal in workspace.terminals {
            guard let placement = terminal.placement,
                  let index = sections.firstIndex(where: { $0.id == placement.sectionID }) else { continue }
            let starts = lastPane[placement.sectionID].map { $0 != placement.paneID } ?? false
            lastPane[placement.sectionID] = placement.paneID
            sections[index].rows.append(MobileSSHTabRow(
                id: MobileSSHIdentifier(host: hostID, local: terminal.id).rawValue,
                title: placement.title,
                paneLabel: placement.paneLabel,
                startsPane: starts
            ))
        }
        return MobileSSHTabLayout(kind: workspace.kind, sections: sections.filter { !$0.rows.isEmpty })
    }

    nonisolated static func sectionActions(kind: MobileSSHWorkspaceKind, targetPane: Int?) -> [MobileSSHSectionAction] {
        switch kind {
        case .tmux: [.splitPane]
        case .cmuxTUI: targetPane == nil ? [] : [.newTab, .splitPane]
        case .shell: []
        }
    }

    /// "New Window" (tmux) / "New Screen" (cmux-tui): returns the new
    /// terminal's scoped surface id after the host's rows are refreshed.
    func createTerminal(inWorkspace scopedID: String) async -> String? {
        guard let hostID = MobileSSHIdentifier(scopedID).hostID,
              let local = MobileSSHLocalID(scopedID: scopedID) else { return nil }
        do {
            guard let created = try await provider(for: hostID).createTerminal(inWorkspace: local) else { return nil }
            await refreshWorkspaces(hostID: hostID)
            return MobileSSHIdentifier(host: hostID, local: created.rawValue).rawValue
        } catch {
            return nil
        }
    }

    /// A section action: "Split Pane" (tmux window), "New Tab" or "Split
    /// Pane" (cmux-tui screen); `nil` runs the section's first action.
    /// Returns the new terminal's scoped surface id.
    func createTab(inWorkspace scopedID: String, section sectionID: String, action: MobileSSHSectionAction? = nil) async -> String? {
        guard let hostID = MobileSSHIdentifier(scopedID).hostID,
              let local = MobileSSHLocalID(scopedID: scopedID) else { return nil }
        let workspace = workspacesByHostSnapshot(hostID)?.first { $0.id == local.rawValue }
        let pane = workspace?.sections.first { $0.id == sectionID }?.targetPane
        let available = Self.sectionActions(kind: local.kind, targetPane: pane)
        guard let action = action ?? available.first, available.contains(action) else { return nil }
        do {
            guard let created = try await provider(for: hostID).createTab(
                inWorkspace: local,
                section: sectionID,
                pane: pane,
                action: action
            ) else {
                return nil
            }
            await refreshWorkspaces(hostID: hostID)
            return MobileSSHIdentifier(host: hostID, local: created.rawValue).rawValue
        } catch {
            return nil
        }
    }
}
