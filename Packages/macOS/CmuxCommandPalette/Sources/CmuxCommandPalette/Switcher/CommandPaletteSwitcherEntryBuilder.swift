internal import Foundation

/// Builds the command-palette switcher entries and the palette's
/// change-detection fingerprints from a host-provided snapshot.
///
/// This is the package home for the switcher half of the palette list: given a
/// ``CommandPaletteWorkspaceSnapshotProviding`` seam that resolves live
/// window/workspace/surface state into plain snapshot values, the builder
/// assembles the ``CommandPaletteCommand`` rows (ids, ranks, keywords, subtitles,
/// actions) and the order-sensitive fingerprints used to decide when the corpus
/// must be rebuilt. The lift is byte-identical to the legacy in-host code: the
/// command ids, rank ordering, keyword construction, subtitle format, and
/// fingerprint inputs are unchanged, and the localized labels / display names /
/// actions are resolved by the seam conformer (host bundle) and carried through
/// the snapshot.
@MainActor
public final class CommandPaletteSwitcherEntryBuilder {
    private let snapshotProvider: any CommandPaletteWorkspaceSnapshotProviding

    /// Creates a builder over the given workspace-snapshot seam.
    public init(snapshotProvider: any CommandPaletteWorkspaceSnapshotProviding) {
        self.snapshotProvider = snapshotProvider
    }

    /// Fingerprints the commands context together with the host config revision.
    ///
    /// `configRevision` is the host config store's monotonically increasing
    /// revision; it is combined as `UInt64` to match the legacy hash input
    /// exactly.
    public func commandsFingerprint(
        commandsContext: CommandPaletteCommandsContext,
        configRevision: UInt64
    ) -> Int {
        var hasher = Hasher()
        hasher.combine(commandsContext.snapshot.fingerprint())
        hasher.combine(configRevision)
        return hasher.finalize()
    }

    /// Order-sensitive fingerprint over every window's switcher contents.
    public func switcherEntriesFingerprint(includeSurfaces: Bool) -> Int {
        let windows = snapshotProvider.makeSwitcherSnapshot(includeSurfaces: includeSurfaces)
        let fingerprintContexts = windows.map { window in
            CommandPaletteSwitcherFingerprintContext(
                windowId: window.windowId,
                windowLabel: window.windowLabel,
                selectedWorkspaceId: window.selectedWorkspaceId,
                workspaces: window.workspaces.map { workspace in
                    CommandPaletteSwitcherFingerprintWorkspace(
                        id: workspace.id,
                        displayName: workspace.displayName,
                        metadata: workspace.metadata,
                        surfaces: workspace.surfaces.map { surface in
                            CommandPaletteSwitcherFingerprintSurface(
                                id: surface.id,
                                displayName: surface.displayName,
                                kindLabel: surface.kindLabel,
                                metadata: surface.metadata
                            )
                        }
                    )
                }
            )
        }
        return CommandPaletteSwitcherFingerprintContext.fingerprint(windowContexts: fingerprintContexts)
    }

    /// Builds the ordered switcher command rows for the current state.
    public func switcherEntries(includeSurfaces: Bool) -> [CommandPaletteCommand] {
        let windows = snapshotProvider.makeSwitcherSnapshot(includeSurfaces: includeSurfaces)
        guard !windows.isEmpty else { return [] }

        var entries: [CommandPaletteCommand] = []
        let estimatedCount = windows.reduce(0) { partial, window in
            let workspaceCount = window.workspaces.count
            guard includeSurfaces else { return partial + workspaceCount }
            let surfaceCount = window.workspaces.reduce(0) { count, workspace in
                count + workspace.surfaces.count
            }
            return partial + workspaceCount + surfaceCount
        }
        entries.reserveCapacity(estimatedCount)
        var nextRank = 0

        for window in windows {
            let workspaces = window.workspaces
            guard !workspaces.isEmpty else { continue }

            let windowKeywords = Self.windowKeywords(windowLabel: window.windowLabel)
            for workspace in workspaces {
                let workspaceName = workspace.displayName
                let workspaceCommandId = "switcher.workspace.\(workspace.id.uuidString.lowercased())"
                let workspaceKeywords = CommandPaletteSwitcherSearchIndexer(
                    baseKeywords: [
                        "workspace",
                        "switch",
                        "go",
                        "open",
                        workspaceName
                    ] + windowKeywords,
                    metadata: workspace.metadata,
                    detail: .workspace
                ).keywords
                let workspaceAction = workspace.action
                entries.append(
                    CommandPaletteCommand(
                        id: workspaceCommandId,
                        rank: nextRank,
                        title: workspaceName,
                        subtitle: Self.switcherSubtitle(base: workspace.subtitleBase, windowLabel: window.windowLabel),
                        shortcutHint: nil,
                        kindLabel: workspace.kindLabel,
                        keywords: workspaceKeywords,
                        dismissOnRun: true,
                        action: workspaceAction
                    )
                )
                nextRank += 1

                guard includeSurfaces else { continue }

                for surface in workspace.surfaces {
                    let surfaceName = surface.displayName
                    let surfaceKindLabel = surface.kindLabel
                    let surfaceCommandId = "switcher.surface.\(surface.id.uuidString.lowercased())"
                    let surfaceKeywords = CommandPaletteSwitcherSearchIndexer(
                        baseKeywords: [
                            "surface",
                            "tab",
                            "switch",
                            "go",
                            "open",
                            surfaceName,
                            workspaceName
                        ] + surface.keywordKind.keywords + windowKeywords,
                        metadata: surface.metadata,
                        detail: .surface
                    ).keywords
                    let surfaceAction = surface.action
                    entries.append(
                        CommandPaletteCommand(
                            id: surfaceCommandId,
                            rank: nextRank,
                            title: surfaceName,
                            subtitle: Self.switcherSubtitle(base: workspaceName, windowLabel: window.windowLabel),
                            shortcutHint: nil,
                            kindLabel: surfaceKindLabel,
                            keywords: surfaceKeywords,
                            dismissOnRun: true,
                            action: surfaceAction
                        )
                    )
                    nextRank += 1
                }
            }
        }

        return entries
    }

    /// The switcher subtitle: the base, optionally suffixed with the window label.
    public static func switcherSubtitle(base: String, windowLabel: String?) -> String {
        guard let windowLabel else { return base }
        return "\(base) • \(windowLabel)"
    }

    /// Static window keywords derived from an optional window label.
    public static func windowKeywords(windowLabel: String?) -> [String] {
        guard let windowLabel else { return [] }
        return ["window", windowLabel.lowercased()]
    }
}
