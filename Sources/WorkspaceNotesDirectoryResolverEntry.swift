import Foundation

/// A window's notes-directory resolver registered with `TerminalSurface`
/// (TerminalSurfaceRuntimeWiring.swift), keyed by its owner so entries can
/// be pruned once the owner is torn down.
struct WorkspaceNotesDirectoryResolverEntry {
    weak var owner: AnyObject?
    let resolve: @MainActor (UUID) -> String?
}
