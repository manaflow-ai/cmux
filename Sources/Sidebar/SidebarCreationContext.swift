import CmuxCore
import CmuxExtensionKit
import CmuxFoundation
import Foundation

/// A machine-level identity used for creation defaults.
///
/// It deliberately excludes workspace ownership, relay tokens, and runtime
/// leases. Multiple workspaces that reach the same machine therefore produce
/// one context row instead of one row per workspace.
struct SidebarRemoteCreationContextKey: Hashable, Sendable {
    let id: String

    init(configuration: WorkspaceRemoteConfiguration) {
        let components: [String]
        if let managedCloudVMID = configuration.managedCloudVMID {
            components = ["managed", managedCloudVMID]
        } else {
            components = [
                configuration.transport.rawValue,
                configuration.destination.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                configuration.port.map(String.init) ?? "",
            ]
        }
        id = "remote-" + Self.stableHash(components.joined(separator: "\u{1f}"))
    }

    private static func stableHash(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}

/// Per-window selection of a parent column and the defaults applied by shared
/// creation actions.
enum SidebarCreationContextSelection: Equatable, Sendable {
    case automatic
    case local
    case remote(SidebarRemoteCreationContextKey)

    static let automaticID = "automatic"
    static let localID = "local"

    var id: String {
        switch self {
        case .automatic:
            return Self.automaticID
        case .local:
            return Self.localID
        case let .remote(key):
            return key.id
        }
    }
}

/// Immutable presentation data consumed by the leading sidebar column and
/// projected into the custom-sidebar interpreter.
struct SidebarCreationContextSnapshot: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable {
        case automatic
        case local
        case remote
    }

    let id: String
    let title: String
    let subtitle: String
    let systemImageName: String
    let isSelected: Bool
    let kind: Kind
    let workspaceCount: Int
    /// Ordered children rendered for this parent. `Automatic` is the aggregate
    /// route and contains every workspace.
    let workspaceIDs: [UUID]
    /// The last focused child for this route in this cmux window.
    let focusedWorkspaceID: UUID?
    let capabilities: Set<CmuxSidebarCreationContextCapability>
    let connectionState: WorkspaceRemoteConnectionState?
    /// Stable parent-owned route to the column rendered after this row.
    let childColumn: CmuxSidebarChildColumn
}

/// Terminal launch values resolved from a selected remote context.
struct SidebarTerminalCreationDefaults: Sendable {
    let contextKey: SidebarRemoteCreationContextKey
    let configuration: WorkspaceRemoteConfiguration

    var initialCommand: String? {
        let command = configuration.terminalStartupCommand?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return command?.isEmpty == false ? command : nil
    }

    var environment: [String: String] {
        configuration.sshTerminalStartupEnvironment ?? [:]
    }
}

/// A machine remembered independently from any workspace currently using it.
/// The durable snapshot excludes relay secrets and workspace-scoped runtime
/// leases, so the context can safely outlive its last open workspace.
struct SidebarRegisteredRemoteCreationContext: Sendable {
    var title: String
    var configuration: WorkspaceRemoteConfiguration
    var durableConfiguration: SessionRemoteWorkspaceSnapshot?
}

/// Builds the durable terminal bridge used to attach the Rust cmux TUI over
/// SSH. The sidebar action owns intent; this builder owns transport quoting.
struct SidebarRemoteCmuxTUIAttachCommand: Equatable, Sendable {
    static let defaultSessionName = "main"
    static let defaultRemoteBinary = "cmux-tui"

    let arguments: [String]
    let command: String
    let sessionName: String

    init?(
        configuration: WorkspaceRemoteConfiguration,
        sessionName rawSessionName: String = defaultSessionName,
        remoteBinary: String = defaultRemoteBinary
    ) {
        guard configuration.transport == .ssh else { return nil }
        let destination = configuration.destination.trimmingCharacters(in: .whitespacesAndNewlines)
        let sessionName = rawSessionName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard SidebarSSHMachineInput.isValidDestination(destination),
              !sessionName.isEmpty,
              sessionName.count <= 128,
              !SidebarSSHMachineInput.hasHiddenCharacter(sessionName),
              !remoteBinary.isEmpty,
              !SidebarSSHMachineInput.hasHiddenCharacter(remoteBinary)
        else {
            return nil
        }

        var arguments = ["/usr/bin/ssh"]
        arguments += SSHHostConfiguredRemoteCommand().overrideArguments
        arguments += [
            "-o", "ClearAllForwardings=yes",
            "-o", "ForwardAgent=no",
            "-o", "ForwardX11=no",
            "-tt",
        ]
        if let port = configuration.port {
            guard (1...65535).contains(port) else { return nil }
            arguments += ["-p", String(port)]
        }
        if let identityFile = configuration.identityFile?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !identityFile.isEmpty
        {
            guard !identityFile.hasPrefix("-"),
                  !SidebarSSHMachineInput.hasHiddenCharacter(identityFile)
            else {
                return nil
            }
            arguments += ["-i", identityFile]
        }
        for option in WorkspaceRemoteConfiguration.trimmedSSHOptions(configuration.sshOptions) {
            arguments += ["-o", option]
        }
        let remoteCommand: String
        if remoteBinary == Self.defaultRemoteBinary {
            // Non-interactive SSH shells often omit ~/.local/bin from PATH,
            // which is cmux-tui's standard remote install location. Prefer an
            // explicit PATH match, then fall back to that durable location.
            remoteCommand = [
                "binary=\"$(command -v 'cmux-tui' 2>/dev/null || printf '%s' \"$HOME/.local/bin/cmux-tui\")\";",
                "exec \"$binary\" attach --session \(Self.shellQuote(sessionName))",
            ].joined(separator: " ")
        } else {
            remoteCommand = [
                "exec",
                Self.shellQuote(remoteBinary),
                "attach",
                "--session",
                Self.shellQuote(sessionName),
            ].joined(separator: " ")
        }
        arguments += ["--", destination, remoteCommand]

        self.arguments = arguments
        self.command = arguments.map(Self.shellQuote).joined(separator: " ")
        self.sessionName = sessionName
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

private enum SidebarSSHMachineInput {
    static func isValidDestination(_ value: String) -> Bool {
        !value.isEmpty &&
            !value.hasPrefix("-") &&
            !hasHiddenCharacter(value) &&
            !value.unicodeScalars.contains { CharacterSet.whitespacesAndNewlines.contains($0) }
    }

    static func hasHiddenCharacter(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator:
                return true
            default:
                return false
            }
        }
    }
}

@MainActor
extension TabManager {
    func canAddSidebarSSHMachine(destination: String) -> Bool {
        SidebarSSHMachineInput.isValidDestination(
            destination.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    func canAttachRemoteCmuxTUI(contextID: String) -> Bool {
        sidebarRemoteContext(forID: contextID)?.configuration.transport == .ssh
    }

    /// Adds a durable SSH machine even when it has no workspace children yet.
    /// Cmd+N and Cmd+T subsequently consume the same registered defaults.
    @discardableResult
    func addSidebarSSHMachine(
        destination rawDestination: String,
        port: Int? = nil,
        identityFile rawIdentityFile: String? = nil,
        sshOptions: [String] = [],
        select: Bool = true
    ) -> String? {
        let destination = rawDestination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard SidebarSSHMachineInput.isValidDestination(destination) else { return nil }
        if let port, !(1...65535).contains(port) { return nil }
        let identityFile = rawIdentityFile?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        if let identityFile,
           identityFile.hasPrefix("-") || SidebarSSHMachineInput.hasHiddenCharacter(identityFile)
        {
            return nil
        }
        let durable = SessionRemoteWorkspaceSnapshot(
            transport: .ssh,
            terminalTransport: .ssh,
            terminalProfile: .shell,
            destination: destination,
            port: port,
            identityFile: identityFile,
            sshOptions: WorkspaceRemoteConfiguration.trimmedSSHOptions(sshOptions)
        )
        guard let configuration = durable.workspaceConfiguration(
            localSocketPath: TerminalController.shared.currentSocketPathForRemoteRestore(),
            allowPersistentPTYRestore: false,
            preserveSSHOptions: true
        ) else {
            return nil
        }
        rememberSidebarRemoteCreationContext(
            configuration: configuration,
            title: configuration.displayTarget
        )
        let contextID = SidebarRemoteCreationContextKey(configuration: configuration).id
        if select {
            _ = selectSidebarCreationContext(id: contextID)
        }
        return contextID
    }

    /// Attaches a remote cmux-TUI session as one terminal surface. The target
    /// workspace remains an independent navigation child, so local and remote
    /// surfaces can be mixed freely.
    @discardableResult
    func attachRemoteCmuxTUI(
        contextID: String,
        sessionName: String = SidebarRemoteCmuxTUIAttachCommand.defaultSessionName,
        workspaceID: UUID? = nil,
        focus: Bool = true
    ) -> TerminalPanel? {
        guard let context = sidebarRemoteContext(forID: contextID),
              let launch = SidebarRemoteCmuxTUIAttachCommand(
                configuration: context.configuration,
                sessionName: sessionName
              )
        else {
            return nil
        }
        let workspace: Workspace?
        if let workspaceID {
            workspace = tabs.first { $0.id == workspaceID }
        } else {
            workspace = selectedWorkspace ?? tabs.first
        }
        guard let workspace, !workspace.isRemoteTmuxMirror else { return nil }
        if focus {
            workspace.clearSplitZoom()
        }
        guard let panel = workspace.newTerminalSurfaceInFocusedPane(
            focus: focus,
            initialCommand: launch.command,
            tmuxStartCommand: launch.command,
            suppressWorkspaceRemoteStartupCommand: true
        ) else {
            return nil
        }
        _ = workspace.setPanelCustomTitle(
            panelId: panel.id,
            title: String(
                format: String(
                    localized: "sidebar.machine.cmuxTUI.surfaceTitle",
                    defaultValue: "cmux · %@"
                ),
                context.configuration.displayTarget
            ),
            source: .auto
        )
        return panel
    }

    /// The context rows available in this window. Live remote configurations
    /// are grouped by machine identity, while workspace membership is an
    /// independent persisted relationship.
    func sidebarCreationContextSnapshots() -> [SidebarCreationContextSnapshot] {
        struct RemoteAggregate {
            var configuration: WorkspaceRemoteConfiguration
            var title: String
            var workspaceCount: Int
            var connectionState: WorkspaceRemoteConnectionState?
        }

        rememberLiveSidebarRemoteCreationContexts()
        rememberSelectedSidebarWorkspaceFocus()
        let remoteOrder = sidebarRemoteCreationContextOrder
        var remotes: [SidebarRemoteCreationContextKey: RemoteAggregate] = Dictionary(
            uniqueKeysWithValues: remoteOrder.compactMap { key in
                guard let registered = sidebarRemoteCreationContexts[key] else { return nil }
                return (
                    key,
                    RemoteAggregate(
                        configuration: registered.configuration,
                        title: registered.title,
                        workspaceCount: 0,
                        connectionState: nil
                    )
                )
            }
        )
        for workspace in tabs {
            guard let configuration = workspace.remoteConfiguration else { continue }
            let key = SidebarRemoteCreationContextKey(configuration: configuration)
            let candidateTitle: String
            if configuration.managedCloudVMID != nil {
                candidateTitle = workspace.customTitle?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                    ?? workspace.title
            } else {
                candidateTitle = configuration.displayTarget
            }
            if var aggregate = remotes[key] {
                aggregate.workspaceCount += 1
                if aggregate.connectionState == nil ||
                    Self.sidebarConnectionStatePriority(workspace.remoteConnectionState)
                    > Self.sidebarConnectionStatePriority(aggregate.connectionState!)
                {
                    aggregate.connectionState = workspace.remoteConnectionState
                    aggregate.configuration = configuration
                    aggregate.title = candidateTitle
                }
                remotes[key] = aggregate
            } else {
                remotes[key] = RemoteAggregate(
                    configuration: configuration,
                    title: candidateTitle,
                    workspaceCount: 1,
                    connectionState: workspace.remoteConnectionState
                )
            }
        }

        for key in Array(remotes.keys) {
            guard var aggregate = remotes[key] else { continue }
            aggregate.workspaceCount = tabs.lazy.filter {
                self.resolvedSidebarCreationContextID(for: $0) == key.id
            }.count
            remotes[key] = aggregate
        }

        let effectiveSelection = effectiveSidebarCreationContextSelection(
            availableRemoteKeys: Set(remoteOrder)
        )
        let allWorkspaceIDs = tabs.map(\.id)
        let localWorkspaceIDs = tabs.compactMap { workspace in
            resolvedSidebarCreationContextID(for: workspace)
                == SidebarCreationContextSelection.localID ? workspace.id : nil
        }
        _ = allWorkspaceIDs
        let local = SidebarCreationContextSnapshot(
            id: SidebarCreationContextSelection.localID,
            title: String(localized: "sidebar.context.local.title", defaultValue: "This Mac"),
            subtitle: String(localized: "sidebar.context.local.subtitle", defaultValue: "Create local terminals"),
            systemImageName: "desktopcomputer",
            isSelected: effectiveSelection == .local,
            kind: .local,
            workspaceCount: localWorkspaceIDs.count,
            workspaceIDs: localWorkspaceIDs,
            focusedWorkspaceID: focusedSidebarWorkspaceID(
                forCreationContextID: SidebarCreationContextSelection.localID
            ),
            capabilities: [],
            connectionState: nil,
            childColumn: .sharedWorkspaces(parentID: SidebarCreationContextSelection.localID)
        )
        var machinesByID = [SidebarCreationContextSelection.localID: local]
        for key in remoteOrder {
            guard let aggregate = remotes[key] else { continue }
            machinesByID[key.id] = SidebarCreationContextSnapshot(
                id: key.id,
                title: aggregate.title,
                subtitle: Self.sidebarRemoteContextSubtitle(
                    state: aggregate.connectionState,
                    workspaceCount: aggregate.workspaceCount
                ),
                systemImageName: aggregate.configuration.managedCloudVMID == nil
                    ? "server.rack"
                    : "cloud.fill",
                isSelected: effectiveSelection == .remote(key),
                kind: .remote,
                workspaceCount: aggregate.workspaceCount,
                workspaceIDs: tabs.compactMap { workspace in
                    resolvedSidebarCreationContextID(for: workspace) == key.id
                        ? workspace.id
                        : nil
                },
                focusedWorkspaceID: focusedSidebarWorkspaceID(forCreationContextID: key.id),
                capabilities: aggregate.configuration.transport == .ssh
                    ? [.attachRemoteCmuxTUI]
                    : [],
                connectionState: aggregate.connectionState,
                childColumn: .sharedWorkspaces(parentID: key.id)
            )
        }
        let machineOrder = reconciledSidebarMachineCreationContextOrder()
        return machineOrder.compactMap { machinesByID[$0] }
    }

    var selectedSidebarCreationContextID: String {
        rememberLiveSidebarRemoteCreationContexts()
        let availableKeys = Set(sidebarRemoteCreationContextOrder)
        return effectiveSidebarCreationContextSelection(availableRemoteKeys: availableKeys).id
    }

    /// The child route owned by the selected context. Built-in contexts share
    /// one renderer implementation, with parent-specific data and identity.
    var selectedSidebarChildColumn: CmuxSidebarChildColumn {
        .sharedWorkspaces(parentID: selectedSidebarCreationContextID)
    }

    /// Workspaces rendered as children of one context. `Automatic` remains an
    /// aggregate route; machine contexts expose only their persisted members.
    func sidebarWorkspaces(forCreationContextID contextID: String) -> [Workspace] {
        if contextID == SidebarCreationContextSelection.automaticID {
            return tabs
        }
        rememberLiveSidebarRemoteCreationContexts()
        guard isValidSidebarWorkspaceParentContextID(contextID) else { return [] }
        return tabs.filter { resolvedSidebarCreationContextID(for: $0) == contextID }
    }

    /// The machine parent currently owning a workspace in the sidebar. This
    /// relationship does not constrain any surface's runtime transport.
    func sidebarCreationContextID(for workspace: Workspace) -> String {
        rememberLiveSidebarRemoteCreationContexts()
        return resolvedSidebarCreationContextID(for: workspace)
    }

    /// Reparents workspaces between machine child columns without touching
    /// their local or remote configurations. Partial group moves ungroup the
    /// moved members so one group cannot straddle two parent columns.
    @discardableResult
    func moveSidebarWorkspaces(
        _ workspaceIDs: [UUID],
        toCreationContextID contextID: String
    ) -> Bool {
        rememberLiveSidebarRemoteCreationContexts()
        guard contextID != SidebarCreationContextSelection.automaticID,
              isValidSidebarWorkspaceParentContextID(contextID)
        else {
            return false
        }

        let requestedIDs = Set(workspaceIDs)
        let moving = tabs.filter { requestedIDs.contains($0.id) }
        guard !moving.isEmpty else { return false }
        let groupMemberIDs = Dictionary(grouping: tabs.compactMap { workspace -> (UUID, UUID)? in
            guard let groupID = workspace.groupId else { return nil }
            return (groupID, workspace.id)
        }, by: \.0).mapValues { Set($0.map(\.1)) }

        objectWillChange.send()
        for workspace in moving {
            if let groupID = workspace.groupId,
               let members = groupMemberIDs[groupID],
               !members.isSubset(of: requestedIDs)
            {
                removeWorkspaceFromGroup(workspaceId: workspace.id)
            }
            workspace.sidebarCreationContextID = contextID
        }
        reconcileSidebarFocusedWorkspaceState()
        if let selectedWorkspace, requestedIDs.contains(selectedWorkspace.id) {
            rememberSelectedSidebarWorkspaceFocus()
        }
        return true
    }

    /// Membership assigned to newly-created workspaces. Automatic leaves the
    /// field unset so legacy local/remote provenance inference remains intact.
    func sidebarCreationContextIDForNewWorkspace() -> String? {
        switch sidebarCreationContextSelection {
        case .automatic:
            return nil
        case .local:
            return SidebarCreationContextSelection.localID
        case let .remote(key):
            return key.id
        }
    }

    @discardableResult
    func selectSidebarCreationContext(id: String) -> Bool {
        rememberLiveSidebarRemoteCreationContexts()
        let nextSelection: SidebarCreationContextSelection
        if id == SidebarCreationContextSelection.automaticID {
            // Legacy id from old snapshots/RPC callers. The machines column
            // lists places only, so the aggregate mode resolves to This Mac.
            nextSelection = .local
        } else if id == SidebarCreationContextSelection.localID {
            nextSelection = .local
        } else if let context = sidebarRemoteContext(forID: id) {
            nextSelection = .remote(context.key)
        } else {
            return false
        }
        rememberSelectedSidebarWorkspaceFocus()
        if sidebarCreationContextSelection != nextSelection {
            sidebarCreationContextSelection = nextSelection
        }
        if id != SidebarCreationContextSelection.automaticID,
           let workspace = preferredSidebarWorkspace(forCreationContextID: id),
           workspace.id != selectedTabId
        {
            selectWorkspace(workspace)
        }
        return true
    }

    /// Returns explicit remote defaults for Cmd+N. Automatic and local keep
    /// the existing local-workspace path, so this is intentionally optional.
    func selectedSidebarRemoteCreationDefaults() -> SidebarTerminalCreationDefaults? {
        guard case let .remote(key) = sidebarCreationContextSelection,
              let context = sidebarRemoteContext(forKey: key)
        else {
            return nil
        }
        let defaults = SidebarTerminalCreationDefaults(
            contextKey: key,
            configuration: context.configuration
        )
        return defaults.initialCommand == nil ? nil : defaults
    }

    /// Keeps a remote available after its last workspace closes. This is the
    /// separation between a creation default and a workspace owner.
    func rememberSidebarRemoteCreationContext(
        configuration: WorkspaceRemoteConfiguration,
        title: String
    ) {
        let key = SidebarRemoteCreationContextKey(configuration: configuration)
        if sidebarRemoteCreationContexts[key] == nil {
            sidebarRemoteCreationContextOrder.append(key)
            sidebarMachineCreationContextOrder.append(key.id)
        }
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        sidebarRemoteCreationContexts[key] = SidebarRegisteredRemoteCreationContext(
            title: normalizedTitle.isEmpty ? configuration.displayTarget : normalizedTitle,
            configuration: configuration,
            durableConfiguration: configuration.sessionSnapshot()
        )
    }

    func sidebarCreationContextSessionSnapshots() -> [SessionSidebarCreationContextSnapshot] {
        rememberLiveSidebarRemoteCreationContexts()
        return sidebarRemoteCreationContextOrder.compactMap { key in
            guard let registered = sidebarRemoteCreationContexts[key],
                  let remote = registered.durableConfiguration
            else {
                return nil
            }
            return SessionSidebarCreationContextSnapshot(
                title: registered.title,
                remote: remote
            )
        }
    }

    func sidebarMachineCreationContextOrderIDs() -> [String] {
        rememberLiveSidebarRemoteCreationContexts()
        return reconciledSidebarMachineCreationContextOrder()
    }

    /// Stable per-machine navigation state persisted with this window.
    func sidebarFocusedWorkspaceSessionSnapshot() -> [String: UUID] {
        rememberSelectedSidebarWorkspaceFocus()
        reconcileSidebarFocusedWorkspaceState()
        return sidebarFocusedWorkspaceStableIDByCreationContextID
    }

    /// Moves one machine row to a final index in the machine-only collection.
    /// `Automatic` remains fixed above the collection because it is a mode.
    @discardableResult
    func reorderSidebarMachineCreationContext(id: String, toIndex requestedIndex: Int) -> Bool {
        rememberLiveSidebarRemoteCreationContexts()
        var order = reconciledSidebarMachineCreationContextOrder()
        guard let sourceIndex = order.firstIndex(of: id) else { return false }
        let destinationIndex = min(max(requestedIndex, 0), order.count - 1)
        guard sourceIndex != destinationIndex else { return true }

        let movedID = order.remove(at: sourceIndex)
        order.insert(movedID, at: min(destinationIndex, order.count))
        objectWillChange.send()
        sidebarMachineCreationContextOrder = order
        return true
    }

    @discardableResult
    func moveSidebarMachineCreationContext(id: String, by offset: Int) -> Bool {
        let order = sidebarMachineCreationContextOrderIDs()
        guard let sourceIndex = order.firstIndex(of: id) else { return false }
        return reorderSidebarMachineCreationContext(id: id, toIndex: sourceIndex + offset)
    }

    func restoreSidebarCreationContexts(
        _ snapshots: [SessionSidebarCreationContextSnapshot],
        selectedContextID: String?,
        machineOrder: [String]? = nil,
        focusedWorkspaceStableIDs: [String: UUID]? = nil
    ) {
        for snapshot in snapshots {
            guard let configuration = snapshot.remote.workspaceConfiguration(
                localSocketPath: TerminalController.shared.currentSocketPathForRemoteRestore(),
                allowPersistentPTYRestore: false,
                preserveSSHOptions: true
            ) else { continue }
            rememberSidebarRemoteCreationContext(
                configuration: configuration,
                title: snapshot.title
            )
        }
        if let machineOrder {
            sidebarMachineCreationContextOrder = reconciledSidebarMachineCreationContextOrder(
                preferredOrder: machineOrder
            )
        }
        if let focusedWorkspaceStableIDs {
            sidebarFocusedWorkspaceStableIDByCreationContextID = focusedWorkspaceStableIDs
            reconcileSidebarFocusedWorkspaceState()
        } else {
            rememberSelectedSidebarWorkspaceFocus()
        }
        if let selectedContextID {
            _ = selectSidebarCreationContext(id: selectedContextID)
        }
    }

    /// Records workspace focus in the workspace's navigation parent. This is
    /// called from the shared selection hook, so keyboard, menu, socket, and
    /// sidebar selection all update the same per-window cursor.
    func rememberSelectedSidebarWorkspaceFocus() {
        guard let selectedWorkspace else { return }
        let contextID = resolvedSidebarCreationContextID(for: selectedWorkspace)
        guard isValidSidebarWorkspaceParentContextID(contextID) else { return }
        sidebarFocusedWorkspaceStableIDByCreationContextID[contextID] = selectedWorkspace.stableId
    }

    /// Finder-style selection cascade: selecting a workspace by any means
    /// (keyboard, palette, socket, sidebar click) highlights its machine in
    /// the machines column and scopes the workspaces column to it. Without
    /// this, a workspace selected via Cmd+1..9 could be invisible in the
    /// currently scoped column.
    func followSidebarMachineSelectionForSelectedWorkspace() {
        guard let selectedWorkspace else { return }
        let contextID = resolvedSidebarCreationContextID(for: selectedWorkspace)
        guard contextID != sidebarCreationContextSelection.id else { return }
        let nextSelection: SidebarCreationContextSelection
        if contextID == SidebarCreationContextSelection.localID {
            nextSelection = .local
        } else if let context = sidebarRemoteContext(forID: contextID) {
            nextSelection = .remote(context.key)
        } else {
            return
        }
        sidebarCreationContextSelection = nextSelection
    }

    func focusedSidebarWorkspaceID(forCreationContextID contextID: String) -> UUID? {
        if contextID == SidebarCreationContextSelection.automaticID {
            return selectedTabId
        }
        return preferredSidebarWorkspace(forCreationContextID: contextID)?.id
    }

    /// Shared Cmd+T implementation. Explicit local and remote contexts can be
    /// mixed inside any non-mirrored workspace; automatic preserves the
    /// workspace's existing behavior.
    @discardableResult
    func newSurfaceUsingSidebarCreationContext(initialInput: String? = nil) -> TerminalPanel? {
        guard let workspace = selectedWorkspace else { return nil }
        workspace.clearSplitZoom()

        switch sidebarCreationContextSelection {
        case .automatic:
            return workspace.newTerminalSurfaceInFocusedPane(
                focus: true,
                initialInput: initialInput
            )
        case .local:
            return workspace.newTerminalSurfaceInFocusedPane(
                focus: true,
                initialInput: initialInput,
                suppressWorkspaceRemoteStartupCommand: true
            )
        case let .remote(key):
            guard let context = sidebarRemoteContext(forKey: key) else {
                return workspace.newTerminalSurfaceInFocusedPane(
                    focus: true,
                    initialInput: initialInput
                )
            }
            if let workspaceConfiguration = workspace.remoteConfiguration,
               SidebarRemoteCreationContextKey(configuration: workspaceConfiguration) == key
            {
                return workspace.newTerminalSurfaceInFocusedPane(
                    focus: true,
                    initialInput: initialInput
                )
            }
            let defaults = SidebarTerminalCreationDefaults(
                contextKey: key,
                configuration: context.configuration
            )
            guard let initialCommand = defaults.initialCommand else {
                return workspace.newTerminalSurfaceInFocusedPane(
                    focus: true,
                    initialInput: initialInput
                )
            }
            return workspace.newTerminalSurfaceInFocusedPane(
                focus: true,
                initialInput: initialInput,
                initialCommand: initialCommand,
                startupEnvironment: defaults.environment,
                suppressWorkspaceRemoteStartupCommand: true
            )
        }
    }

    private func effectiveSidebarCreationContextSelection(
        availableRemoteKeys: Set<SidebarRemoteCreationContextKey>
    ) -> SidebarCreationContextSelection {
        switch sidebarCreationContextSelection {
        case .automatic:
            // Legacy persisted mode; the column shows places only.
            return .local
        case .local:
            return .local
        case let .remote(key):
            return availableRemoteKeys.contains(key) ? .remote(key) : .local
        }
    }

    private func preferredSidebarWorkspace(forCreationContextID contextID: String) -> Workspace? {
        let children = tabs.filter { resolvedSidebarCreationContextID(for: $0) == contextID }
        guard !children.isEmpty else { return nil }
        if let selectedWorkspace,
           children.contains(where: { $0.id == selectedWorkspace.id })
        {
            return selectedWorkspace
        }
        if let stableID = sidebarFocusedWorkspaceStableIDByCreationContextID[contextID],
           let remembered = children.first(where: { $0.stableId == stableID })
        {
            return remembered
        }
        return children.first
    }

    private func reconcileSidebarFocusedWorkspaceState() {
        sidebarFocusedWorkspaceStableIDByCreationContextID =
            sidebarFocusedWorkspaceStableIDByCreationContextID.filter { contextID, stableID in
                contextID != SidebarCreationContextSelection.automaticID &&
                    isValidSidebarWorkspaceParentContextID(contextID) &&
                    tabs.contains { workspace in
                        workspace.stableId == stableID &&
                            resolvedSidebarCreationContextID(for: workspace) == contextID
                    }
            }
    }

    private func sidebarRemoteContext(
        forID id: String
    ) -> (key: SidebarRemoteCreationContextKey, configuration: WorkspaceRemoteConfiguration)? {
        rememberLiveSidebarRemoteCreationContexts()
        guard let key = sidebarRemoteCreationContextOrder.first(where: { $0.id == id }) else {
            return nil
        }
        return sidebarRemoteContext(forKey: key)
    }

    private func sidebarRemoteContext(
        forKey key: SidebarRemoteCreationContextKey
    ) -> (key: SidebarRemoteCreationContextKey, configuration: WorkspaceRemoteConfiguration)? {
        let matching = tabs.compactMap { workspace -> (Workspace, WorkspaceRemoteConfiguration)? in
            guard let configuration = workspace.remoteConfiguration,
                  SidebarRemoteCreationContextKey(configuration: configuration) == key
            else {
                return nil
            }
            return (workspace, configuration)
        }
        let preferred = matching.max { lhs, rhs in
            Self.sidebarConnectionStatePriority(lhs.0.remoteConnectionState)
                < Self.sidebarConnectionStatePriority(rhs.0.remoteConnectionState)
        }
        let configuration = preferred?.1 ?? sidebarRemoteCreationContexts[key]?.configuration
        guard let configuration else { return nil }
        return (key, reusableSidebarRemoteConfiguration(configuration))
    }

    private func rememberLiveSidebarRemoteCreationContexts() {
        for workspace in tabs {
            guard let configuration = workspace.remoteConfiguration else { continue }
            let title = configuration.managedCloudVMID == nil
                ? configuration.displayTarget
                : (workspace.customTitle?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nilIfEmpty ?? workspace.title)
            rememberSidebarRemoteCreationContext(
                configuration: configuration,
                title: title
            )
        }
    }

    private func reconciledSidebarMachineCreationContextOrder(
        preferredOrder: [String]? = nil
    ) -> [String] {
        let availableIDs = [SidebarCreationContextSelection.localID]
            + sidebarRemoteCreationContextOrder.map(\.id)
        let availableSet = Set(availableIDs)
        var seen: Set<String> = []
        var result = (preferredOrder ?? sidebarMachineCreationContextOrder).filter { id in
            availableSet.contains(id) && seen.insert(id).inserted
        }
        result.append(contentsOf: availableIDs.filter { seen.insert($0).inserted })
        return result
    }

    private func reusableSidebarRemoteConfiguration(
        _ configuration: WorkspaceRemoteConfiguration
    ) -> WorkspaceRemoteConfiguration {
        configuration.sessionSnapshot()?.workspaceConfiguration(
            localSocketPath: TerminalController.shared.currentSocketPathForRemoteRestore(),
            allowPersistentPTYRestore: false,
            preserveSSHOptions: true,
            agentSocketPath: configuration.agentSocketPath
        ) ?? configuration
    }

    private func isValidSidebarWorkspaceParentContextID(_ contextID: String) -> Bool {
        contextID == SidebarCreationContextSelection.localID
            || sidebarRemoteCreationContextOrder.contains { $0.id == contextID }
    }

    private func resolvedSidebarCreationContextID(for workspace: Workspace) -> String {
        if let explicit = workspace.sidebarCreationContextID?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !explicit.isEmpty,
           isValidSidebarWorkspaceParentContextID(explicit)
        {
            return explicit
        }

        // A group is one child subtree. Legacy mixed-locality groups follow
        // their anchor so restore never fragments a group across machines.
        if let groupID = workspace.groupId,
           let group = workspaceGroups.first(where: { $0.id == groupID }),
           let anchor = tabs.first(where: { $0.id == group.anchorWorkspaceId }),
           anchor !== workspace
        {
            if let explicit = anchor.sidebarCreationContextID?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !explicit.isEmpty,
               isValidSidebarWorkspaceParentContextID(explicit)
            {
                return explicit
            }
            return directSidebarCreationContextID(for: anchor)
        }
        return directSidebarCreationContextID(for: workspace)
    }

    private func directSidebarCreationContextID(for workspace: Workspace) -> String {
        guard let configuration = workspace.remoteConfiguration else {
            return SidebarCreationContextSelection.localID
        }
        return SidebarRemoteCreationContextKey(configuration: configuration).id
    }

    private static func sidebarConnectionStatePriority(
        _ state: WorkspaceRemoteConnectionState
    ) -> Int {
        switch state {
        case .connected:
            return 4
        case .connecting, .reconnecting:
            return 3
        case .error, .suspended:
            return 2
        case .disconnected:
            return 1
        }
    }

    private static func sidebarRemoteContextSubtitle(
        state: WorkspaceRemoteConnectionState?,
        workspaceCount: Int
    ) -> String {
        guard let state else {
            return String(
                localized: "sidebar.context.remote.noWorkspaces",
                defaultValue: "No open workspaces"
            )
        }
        let stateText: String
        switch state {
        case .connected:
            stateText = String(localized: "sidebar.context.state.connected", defaultValue: "Connected")
        case .connecting:
            stateText = String(localized: "sidebar.context.state.connecting", defaultValue: "Connecting")
        case .reconnecting:
            stateText = String(localized: "sidebar.context.state.reconnecting", defaultValue: "Reconnecting")
        case .error:
            stateText = String(localized: "sidebar.context.state.error", defaultValue: "Connection error")
        case .suspended:
            stateText = String(localized: "sidebar.context.state.suspended", defaultValue: "Reconnect required")
        case .disconnected:
            stateText = String(localized: "sidebar.context.state.disconnected", defaultValue: "Disconnected")
        }
        guard workspaceCount > 1 else { return stateText }
        return String(
            format: String(
                localized: "sidebar.context.remote.workspaceCount",
                defaultValue: "%1$@ · %2$d workspaces"
            ),
            stateText,
            workspaceCount
        )
    }
}

#if DEBUG
@MainActor
extension TabManager {
    /// Deterministic local/remote membership fixture for the focused sidebar
    /// columns UI test. It never starts a connection.
    func setupUITestSidebarMachineScopesIfNeeded() {
        guard ProcessInfo.processInfo.environment["CMUX_UI_TEST_SIDEBAR_MACHINE_SCOPES"] == "1",
              let localWorkspace = tabs.first,
              tabs.count == 1
        else {
            return
        }
        setCustomTitle(tabId: localWorkspace.id, title: "Local Fixture")
        let remoteWorkspace = addWorkspace(
            title: "Remote Fixture",
            select: false,
            autoWelcomeIfNeeded: false
        )
        remoteWorkspace.remoteConfiguration = WorkspaceRemoteConfiguration(
            destination: "fixture@example.test",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: nil,
            relayID: nil,
            relayToken: nil,
            localSocketPath: nil,
            ownerWorkspaceID: remoteWorkspace.id,
            terminalStartupCommand: "ssh fixture@example.test"
        )
        remoteWorkspace.remoteConnectionState = .disconnected
        rememberLiveSidebarRemoteCreationContexts()
    }
}
#endif
