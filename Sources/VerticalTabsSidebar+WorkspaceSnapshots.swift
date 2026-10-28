import CmuxSidebar
import CmuxWorkspaces
import Foundation
import SwiftUI

/// Workspace row snapshot refresh for the sidebar, extracted from `ContentView.swift`, which sits at
/// its file-length budget. Row colors, origin hosts and group colors resolve here, above the row
/// boundary, into plain values on each snapshot.
extension VerticalTabsSidebar {
    func scheduleWorkspaceSnapshotRefresh(workspaceId: UUID) {
        workspaceSnapshotRefreshCoalescer.schedule(workspaceId: workspaceId) { [sidebarState] workspaceIds in
            guard sidebarState.isVisible else { return }
            refreshWorkspaceSnapshots(workspaceIds: workspaceIds)
        }
    }

    func refreshWorkspaceSnapshots(workspaceIds: Set<UUID>) {
        guard !workspaceIds.isEmpty else { return }
        let workspaceById = Dictionary(uniqueKeysWithValues: tabManager.tabs.map { ($0.id, $0) })
        let settings = tabItemSettingsStore.snapshot
        let showsAgentActivity = settings.details.showAgentActivity
            && CmuxFeatureFlags.shared.isSidebarWorkspaceAgentSpinnerEnabled
        let presentation = originPresentationValues(
            tabs: tabManager.tabs,
            changedWorkspaceIds: workspaceIds
        )
        let mirrorDestinations = presentation.mirrorDestinations
        let hostTitleSuffixes = presentation.hostTitleSuffixes
        let groupColorHexes = workspaceGroupColorHexes(tabs: tabManager.tabs)
        // A rename can start or end a title collision, which changes the host shown on OTHER rows,
        // and a group's color can change without its members changing (the anchor moving into
        // another byCwd entry). Rebuild every row whose saved key no longer matches.
        let staleIds = tabManager.tabs.compactMap { workspace -> UUID? in
            guard let saved = workspaceSnapshotCache.snapshotsById[workspace.id] else { return nil }
            let key = SidebarWorkspaceSnapshotFactory.presentationKey(
                workspace: workspace,
                settings: settings,
                showsAgentActivity: showsAgentActivity,
                groupColorHex: groupColorHexes[workspace.id],
                originColorHex: originColorHex(for: workspace, mirrorDestinations: mirrorDestinations),
                hostTitleSuffix: hostTitleSuffixes[workspace.id]
            )
            return saved.presentationKey == key ? nil : workspace.id
        }
        workspaceSnapshotCache.refresh(
            workspaceIds: workspaceIds.union(staleIds).union(presentation.changedMirrorWorkspaceIds)
        ) { workspaceId in
            guard let workspace = workspaceById[workspaceId] else { return nil }
            return makeWorkspaceSnapshot(
                workspace: workspace,
                settings: settings,
                showsAgentActivity: showsAgentActivity,
                mirrorDestinations: mirrorDestinations,
                groupColorHexes: groupColorHexes,
                hostTitleSuffixes: hostTitleSuffixes
            )
        }
    }

    func refreshWorkspaceSnapshots() {
        let tabs = tabManager.tabs
        let workspaceById = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
        let settings = tabItemSettingsStore.snapshot
        let showsAgentActivity = settings.details.showAgentActivity
            && CmuxFeatureFlags.shared.isSidebarWorkspaceAgentSpinnerEnabled
        let presentation = originPresentationValues(tabs: tabs)
        let mirrorDestinations = presentation.mirrorDestinations
        let hostTitleSuffixes = presentation.hostTitleSuffixes
        let groupColorHexes = workspaceGroupColorHexes(tabs: tabs)
        // The effective color and the host after a colliding title differ per row, so each row's
        // cached snapshot is reused only when its own key still matches.
        workspaceSnapshotCache.reconcile(
            workspaceIds: Set(workspaceById.keys),
            presentationKey: { workspaceId in
                guard let workspace = workspaceById[workspaceId] else {
                    return SidebarWorkspaceSnapshotFactory.presentationKey(
                        settings: settings,
                        showsAgentActivity: showsAgentActivity,
                        customColorHex: nil,
                        hostTitleSuffix: hostTitleSuffixes[workspaceId]
                    )
                }
                return SidebarWorkspaceSnapshotFactory.presentationKey(
                    workspace: workspace,
                    settings: settings,
                    showsAgentActivity: showsAgentActivity,
                    groupColorHex: groupColorHexes[workspaceId],
                    originColorHex: originColorHex(for: workspace, mirrorDestinations: mirrorDestinations),
                    hostTitleSuffix: hostTitleSuffixes[workspaceId]
                )
            }
        ) { workspaceId in
            guard let workspace = workspaceById[workspaceId] else { return nil }
            return makeWorkspaceSnapshot(
                workspace: workspace,
                settings: settings,
                showsAgentActivity: showsAgentActivity,
                mirrorDestinations: mirrorDestinations,
                groupColorHexes: groupColorHexes,
                hostTitleSuffixes: hostTitleSuffixes
            )
        }
    }

    private func makeWorkspaceSnapshot(
        workspace: Workspace,
        settings: SidebarTabItemSettingsSnapshot,
        showsAgentActivity: Bool,
        mirrorDestinations: [UUID: String]?,
        groupColorHexes: [UUID: String],
        hostTitleSuffixes: [UUID: String]
    ) -> SidebarWorkspaceSnapshotBuilder.Snapshot {
#if DEBUG
        sidebarLazyContractProbe.workspaceSnapshotBuild?()
#endif
        return SidebarWorkspaceSnapshotFactory(
            workspace: workspace,
            settings: settings,
            showsAgentActivity: showsAgentActivity,
            originColorHex: originColorHex(for: workspace, mirrorDestinations: mirrorDestinations),
            groupColorHex: groupColorHexes[workspace.id],
            hostTitleSuffix: hostTitleSuffixes[workspace.id]
        ).makeSnapshot()
    }

    /// The group color each grouped workspace inherits; it feeds the effective row color, so a
    /// change rebuilds the affected rows like any other presentation change.
    func workspaceGroupColorHexes(tabs: [Workspace]) -> [UUID: String] {
        SidebarWorkspaceGroupAppearance.inheritedColorHexes(
            workspaces: tabs,
            groups: tabManager.workspaceGroups,
            configStore: cmuxConfigStore
        )
    }

    /// Per-host origin color (beta), resolved here — above the row boundary — to
    /// a plain value. Nil when the flag is off or the workspace has no host.
    ///
    /// Mirror workspaces carry their host only through the session mirror, so callers
    /// pass `mirrorDestinations` and the mirrors get walked once for a whole refresh
    /// rather than once per row. That map comes from `mirrorDestinationsForOriginPresentation()`.
    private func originColorHex(
        for workspace: Workspace,
        mirrorDestinations: [UUID: String]?
    ) -> String? {
        guard remoteTmuxOriginColorsEnabled,
              let destination = originDestination(for: workspace, mirrorDestinations: mirrorDestinations)
        else { return nil }
        return AppDelegate.shared?.remoteTmuxController.hostColorRegistry.colorHex(for: destination)
    }

    /// Hosts to name after colliding workspace titles (beta), over the whole workspace list because
    /// whether a title collides depends on every other title. Empty while the flag is off.
    private func hostTitleSuffixes(tabs: [Workspace], mirrorDestinations: [UUID: String]?) -> [UUID: String] {
        guard remoteTmuxOriginHostTitlesEnabled else { return [:] }
        return RemoteHostTitleSuffixes().suffixes(for: tabs.map { workspace in
            RemoteHostTitleSuffixes.Entry(
                id: workspace.id,
                title: workspace.title,
                destination: RemoteHostTitleSuffixes().origin(
                    destination: originDestination(for: workspace, mirrorDestinations: mirrorDestinations),
                    cloudVMID: workspace.cloudVMID
                )
            )
        })
    }

    /// The remote destination a workspace comes from, or nil for a local workspace or a mirror whose
    /// host has not resolved yet.
    private func originDestination(for workspace: Workspace, mirrorDestinations: [UUID: String]?) -> String? {
        var destination = workspace.remoteConfiguration?.destination
        if destination == nil, workspace.isRemoteTmuxMirror {
            destination = mirrorDestinations?[workspace.id]
        }
        guard let destination, !destination.isEmpty else { return nil }
        return destination
    }

    /// Resolves the shared origin inputs once per changed batch. Mirror destinations are retained
    /// until the mirror set or an affected mirror changes; title suffixes are recomputed only when
    /// their `(id, title, destination, cloudVMID)` inputs differ.
    private func originPresentationValues(
        tabs: [Workspace],
        changedWorkspaceIds: Set<UUID>? = nil
    ) -> (
        mirrorDestinations: [UUID: String]?,
        hostTitleSuffixes: [UUID: String],
        changedMirrorWorkspaceIds: Set<UUID>
    ) {
        let colorsEnabled = remoteTmuxOriginColorsEnabled
        let hostTitlesEnabled = remoteTmuxOriginHostTitlesEnabled
        guard colorsEnabled || hostTitlesEnabled else {
            sidebarOriginPresentationCache.reset()
            return (nil, [:], [])
        }

        let mirrorWorkspaceIds = Set(tabs.filter(\.isRemoteTmuxMirror).map(\.id))
        let mirrorController = AppDelegate.shared?.remoteTmuxController
        let mirrorDestinationsGeneration = mirrorController?.hostDestinationsGeneration ?? 0
        let flagsChanged = sidebarOriginPresentationCache.colorsEnabled != colorsEnabled
            || sidebarOriginPresentationCache.hostTitlesEnabled != hostTitlesEnabled
        let mirrorSetChanged = sidebarOriginPresentationCache.mirrorWorkspaceIds != mirrorWorkspaceIds
        let affectedMirrorChanged = changedWorkspaceIds?.contains { mirrorWorkspaceIds.contains($0) } == true
        let mirrorDestinationsGenerationChanged =
            sidebarOriginPresentationCache.mirrorDestinationsGeneration != mirrorDestinationsGeneration
        let shouldReloadMirrorDestinations = !sidebarOriginPresentationCache.hasLoadedMirrorDestinations
            || flagsChanged
            || mirrorSetChanged
            || affectedMirrorChanged
            || mirrorDestinationsGenerationChanged
        let previousMirrorDestinations = sidebarOriginPresentationCache.mirrorDestinations
        if shouldReloadMirrorDestinations {
            sidebarOriginPresentationCache.mirrorDestinations =
                mirrorController?.hostDestinationsByWorkspaceId() ?? [:]
            sidebarOriginPresentationCache.mirrorDestinationsGeneration = mirrorDestinationsGeneration
            sidebarOriginPresentationCache.hasLoadedMirrorDestinations = true
        }

        let mirrorDestinations = sidebarOriginPresentationCache.mirrorDestinations
        let changedMirrorWorkspaceIds = Set(
            Set(previousMirrorDestinations.keys)
                .union(mirrorDestinations.keys)
                .filter { previousMirrorDestinations[$0] != mirrorDestinations[$0] }
        )
        let inputs = Dictionary(uniqueKeysWithValues: tabs.map { workspace in
            let destination = originDestination(for: workspace, mirrorDestinations: mirrorDestinations)
            return (
                workspace.id,
                SidebarOriginPresentationInput(
                    id: workspace.id,
                    title: workspace.title,
                    destination: destination,
                    cloudVMID: workspace.cloudVMID
                )
            )
        })
        if hostTitlesEnabled {
            if flagsChanged || sidebarOriginPresentationCache.workspaceInputs != inputs {
                sidebarOriginPresentationCache.hostTitleSuffixes = hostTitleSuffixes(
                    tabs: tabs,
                    mirrorDestinations: mirrorDestinations
                )
            }
        } else {
            sidebarOriginPresentationCache.hostTitleSuffixes = [:]
        }
        sidebarOriginPresentationCache.workspaceInputs = inputs
        sidebarOriginPresentationCache.workspaceIds = Set(inputs.keys)
        sidebarOriginPresentationCache.mirrorWorkspaceIds = mirrorWorkspaceIds
        sidebarOriginPresentationCache.colorsEnabled = colorsEnabled
        sidebarOriginPresentationCache.hostTitlesEnabled = hostTitlesEnabled
        return (
            colorsEnabled || hostTitlesEnabled ? mirrorDestinations : nil,
            hostTitlesEnabled ? sidebarOriginPresentationCache.hostTitleSuffixes : [:],
            changedMirrorWorkspaceIds
        )
    }
}
