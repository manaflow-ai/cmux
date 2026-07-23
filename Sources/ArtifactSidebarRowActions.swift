import CmuxArtifacts

/// Closure-only action bundle passed below the project-file lazy-list boundary.
struct ArtifactSidebarRowActions {
    let activate: (ArtifactSidebarRowSnapshot) -> Void
    let toggleExpansion: (ArtifactSidebarRowSnapshot) -> Void
    let revealInFinder: (ArtifactSidebarRowSnapshot) -> Void
    let copyPath: (ArtifactSidebarRowSnapshot) -> Void
    let copyReference: (ArtifactSidebarRowSnapshot) -> Void
}
