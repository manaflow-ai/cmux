import AppKit

/// Closure-only actions passed to an artifact row.
struct ArtifactPaneRowActions {
    let open: (ArtifactPaneRowSnapshot) -> Void
    let copy: (ArtifactPaneRowSnapshot) -> Void
    let reveal: (ArtifactPaneRowSnapshot) -> Void
    let remove: (ArtifactPaneRowSnapshot) -> Void
    let clearAll: () -> Void
    let dragProvider: (ArtifactPaneRowSnapshot) -> NSItemProvider
}
