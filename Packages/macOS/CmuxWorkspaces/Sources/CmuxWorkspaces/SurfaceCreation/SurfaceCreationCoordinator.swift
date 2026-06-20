public import Foundation

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
    public init() {}

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
}
