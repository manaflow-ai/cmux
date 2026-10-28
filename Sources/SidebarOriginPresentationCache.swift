import Foundation

/// Per-workspace origin inputs the sidebar compares to decide when host title suffixes change.
struct SidebarOriginPresentationInput: Equatable {
    let id: UUID
    let title: String
    let destination: String?
    let cloudVMID: String?
}

/// Origin presentation state the sidebar keeps between snapshot refreshes, so mirror hosts and
/// host title suffixes are recomputed only when their inputs change.
@MainActor
final class SidebarOriginPresentationCache {
    var workspaceInputs: [UUID: SidebarOriginPresentationInput] = [:]
    var workspaceIds: Set<UUID> = []
    var mirrorWorkspaceIds: Set<UUID> = []
    var mirrorDestinations: [UUID: String] = [:]
    var mirrorDestinationsGeneration: UInt64?
    var hasLoadedMirrorDestinations = false
    var colorsEnabled = false
    var hostTitlesEnabled = false
    var hostTitleSuffixes: [UUID: String] = [:]

    func reset() {
        workspaceInputs = [:]
        workspaceIds = []
        mirrorWorkspaceIds = []
        mirrorDestinations = [:]
        mirrorDestinationsGeneration = nil
        hasLoadedMirrorDestinations = false
        colorsEnabled = false
        hostTitlesEnabled = false
        hostTitleSuffixes = [:]
    }
}

