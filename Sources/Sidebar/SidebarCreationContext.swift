import CmuxCore
import CmuxExtensionKit
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

/// Per-window selection of the defaults applied by shared creation actions.
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

@MainActor
extension TabManager {
    /// The context rows available in this window. Live remote configurations
    /// are grouped by machine identity, never by workspace id.
    func sidebarCreationContextSnapshots() -> [SidebarCreationContextSnapshot] {
        struct RemoteAggregate {
            var configuration: WorkspaceRemoteConfiguration
            var title: String
            var workspaceCount: Int
            var connectionState: WorkspaceRemoteConnectionState?
        }

        rememberLiveSidebarRemoteCreationContexts()
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

        let effectiveSelection = effectiveSidebarCreationContextSelection(
            availableRemoteKeys: Set(remoteOrder)
        )
        let automatic = SidebarCreationContextSnapshot(
            id: SidebarCreationContextSelection.automaticID,
            title: String(localized: "sidebar.context.automatic.title", defaultValue: "Automatic"),
            subtitle: String(
                localized: "sidebar.context.automatic.subtitle",
                defaultValue: "Keep each action's current behavior"
            ),
            systemImageName: "wand.and.stars",
            isSelected: effectiveSelection == .automatic,
            kind: .automatic,
            workspaceCount: 0,
            connectionState: nil,
            childColumn: .sharedWorkspaces(parentID: SidebarCreationContextSelection.automaticID)
        )
        let local = SidebarCreationContextSnapshot(
            id: SidebarCreationContextSelection.localID,
            title: String(localized: "sidebar.context.local.title", defaultValue: "This Mac"),
            subtitle: String(localized: "sidebar.context.local.subtitle", defaultValue: "Create local terminals"),
            systemImageName: "desktopcomputer",
            isSelected: effectiveSelection == .local,
            kind: .local,
            workspaceCount: tabs.filter { $0.remoteConfiguration == nil }.count,
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
                    ? "network"
                    : "cloud.fill",
                isSelected: effectiveSelection == .remote(key),
                kind: .remote,
                workspaceCount: aggregate.workspaceCount,
                connectionState: aggregate.connectionState,
                childColumn: .sharedWorkspaces(parentID: key.id)
            )
        }
        let machineOrder = reconciledSidebarMachineCreationContextOrder()
        return [automatic] + machineOrder.compactMap { machinesByID[$0] }
    }

    var selectedSidebarCreationContextID: String {
        rememberLiveSidebarRemoteCreationContexts()
        let availableKeys = Set(sidebarRemoteCreationContextOrder)
        return effectiveSidebarCreationContextSelection(availableRemoteKeys: availableKeys).id
    }

    /// The child route owned by the selected context. All built-in contexts
    /// currently resolve to the shared workspace renderer, but keep distinct
    /// route identities so parents can evolve independently.
    var selectedSidebarChildColumn: CmuxSidebarChildColumn {
        .sharedWorkspaces(parentID: selectedSidebarCreationContextID)
    }

    @discardableResult
    func selectSidebarCreationContext(id: String) -> Bool {
        rememberLiveSidebarRemoteCreationContexts()
        let nextSelection: SidebarCreationContextSelection
        if id == SidebarCreationContextSelection.automaticID {
            nextSelection = .automatic
        } else if id == SidebarCreationContextSelection.localID {
            nextSelection = .local
        } else if let context = sidebarRemoteContext(forID: id) {
            nextSelection = .remote(context.key)
        } else {
            return false
        }
        guard sidebarCreationContextSelection != nextSelection else { return true }
        sidebarCreationContextSelection = nextSelection
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
        machineOrder: [String]? = nil
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
        if let selectedContextID {
            _ = selectSidebarCreationContext(id: selectedContextID)
        }
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
        guard case let .remote(key) = sidebarCreationContextSelection else {
            return sidebarCreationContextSelection
        }
        return availableRemoteKeys.contains(key) ? .remote(key) : .automatic
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
